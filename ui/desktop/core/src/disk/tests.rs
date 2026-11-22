//! The engine against a mock Disk API: pull → list → download → upload →
//! conflict. Blocking reqwest runs on spawn_blocking inside the mock's runtime.

use serde_json::json;
use wiremock::matchers::{body_partial_json, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

use super::engine::{DiskConfig, DiskEngine, NoProgress};
use super::model::*;

const BASE: &str = "/api/v1/orgs/org_a/disk";

fn node(id: &str, parent: Option<&str>, kind: &str, name: &str, version: Option<(&str, u64)>, seq: i64) -> serde_json::Value {
    json!({
        "id": id, "parent_id": parent, "drive": "c", "kind": kind, "name": name, "sealed": false,
        "size_bytes": version.map(|v| v.1).unwrap_or(0), "change_seq": seq, "can_write": true,
        "content_modified_at": "2026-11-22T10:00:00Z",
        "current_version": version.map(|(vid, size)| json!({"id": vid, "size_bytes": size})),
    })
}

async fn mock_server() -> MockServer {
    let s = MockServer::start().await;
    let root = node("dnd_root", None, "folder", "", None, 1);
    let file = node("dnd_f", Some("dnd_root"), "file", "Offer.docx", Some(("dvr_1", 5)), 2);
    Mock::given(method("GET")).and(path(format!("{BASE}/sync/pull")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "cursor": "10.0", "has_more": false, "nodes": [root, file], "deleted": []
        }))).mount(&s).await;
    Mock::given(method("GET")).and(path(format!("{BASE}/versions/dvr_1/download")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"download": {"url": format!("{}/blob/1", s.uri())}})))
        .mount(&s).await;
    Mock::given(method("GET")).and(path("/blob/1")).respond_with(ResponseTemplate::new(200).set_body_bytes(b"hello".to_vec())).mount(&s).await;
    Mock::given(method("POST")).and(path(format!("{BASE}/uploads")))
        .respond_with(ResponseTemplate::new(201).set_body_json(json!({"upload": {
            "id": "dup_1", "state": "reserved", "part_bytes": 8388608, "part_count": 1, "node_id": "dnd_new"
        }}))).mount(&s).await;
    Mock::given(method("POST")).and(path(format!("{BASE}/uploads/dup_1/parts")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"parts": [{"number": 1, "url": format!("{}/put/1", s.uri())}]})))
        .mount(&s).await;
    Mock::given(method("PUT")).and(path("/put/1")).respond_with(ResponseTemplate::new(200)).mount(&s).await;
    // An edit based on an old version conflicts; everything else completes.
    Mock::given(method("POST")).and(path(format!("{BASE}/uploads/dup_1/complete"))).and(body_partial_json(json!({"base_version": "dvr_0"})))
        .respond_with(ResponseTemplate::new(409).set_body_json(json!({"errors": [{"message": "changed"}], "code": "version_conflict"})))
        .with_priority(1).mount(&s).await;
    Mock::given(method("POST")).and(path(format!("{BASE}/uploads/dup_1/complete")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"node": node("dnd_new", Some("dnd_root"), "file", "x", Some(("dvr_9", 3)), 5)})))
        .with_priority(5).mount(&s).await;
    Mock::given(method("DELETE")).and(path(format!("{BASE}/uploads/dup_1"))).respond_with(ResponseTemplate::new(200).set_body_json(json!({}))).mount(&s).await;
    Mock::given(method("GET")).and(path(format!("{BASE}/sync/nodes"))).and(query_param("ids[]", "dnd_new"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"nodes": [
            node("dnd_new", Some("dnd_root"), "file", "Offer (Waseem's conflicted copy 2026-11-22).docx", Some(("dvr_9", 3)), 6)
        ]}))).mount(&s).await;
    Mock::given(method("GET")).and(path(format!("{BASE}/sync/nodes"))).and(query_param("ids[]", "dnd_f"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"nodes": [
            node("dnd_f", Some("dnd_root"), "file", "Offer.docx", Some(("dvr_1", 5)), 2)
        ]}))).mount(&s).await;
    s
}

#[tokio::test(flavor = "multi_thread")]
async fn pull_list_fetch_upload_and_conflict() {
    let s = mock_server().await;
    let uri = s.uri();
    tokio::task::spawn_blocking(move || {
        let dir = tempfile::tempdir().unwrap();
        let cfg = DiskConfig { api_base: format!("{uri}/api/v1"), org: "org_a".into(), token: "t".into(), member_name: "Waseem".into(), ..Default::default() };
        let e = DiskEngine::with_config(dir.path(), cfg).unwrap();

        assert!(e.sync().unwrap());
        let top = e.children(ROOT_ID).unwrap();
        assert_eq!(top.len(), 1);
        assert_eq!(top[0].filename, MY_FILES);
        let files = e.children("dnd_root").unwrap();
        assert_eq!(files[0].filename, "Offer.docx");
        assert_eq!(files[0].content_version, "dvr_1");
        // A second sync with nothing new changes nothing macOS sees.
        assert!(!e.sync().unwrap());

        let got = e.fetch("dnd_f", &NoProgress).unwrap();
        assert_eq!(std::fs::read(got).unwrap(), b"hello");

        let src = dir.path().join("new.txt");
        std::fs::write(&src, b"abc").unwrap();
        let made = e.create_file("dnd_root", "new.txt", &src, "op1", &NoProgress).unwrap();
        assert_eq!(made.id, "dnd_new");
        assert_eq!(e.status().uploading, 0, "a finished upload leaves no resume state");

        // Edited from dvr_0 while the server is at dvr_1: the Mac's copy lands beside it.
        let w = e.modify_contents("dnd_f", "dvr_0", &src, &NoProgress).unwrap();
        assert_eq!(w.item.content_version, "dvr_1");
        assert_eq!(w.conflict_copy.unwrap().filename, "Offer (Waseem's conflicted copy 2026-11-22).docx");

        let c = e.changes_since(0).unwrap();
        assert!(c.updated.iter().any(|i| i.id == "dnd_new"));
        assert!(e.create_folder(ROOT_ID, "x", "op2").is_err(), "nothing is added beside the drives");

        // Settings: hide My files, then keep everything downloaded.
        let before = e.anchor().unwrap();
        let mut cfg = e.cfg();
        cfg.hidden_drives = vec!["c".into()];
        std::thread::sleep(std::time::Duration::from_millis(20));
        crate::disk::engine::write_config(dir.path(), &cfg).unwrap();
        e.settings_changed(&["c".into()], false).unwrap();
        assert!(e.children(ROOT_ID).unwrap().is_empty());
        let c = e.changes_since(before).unwrap();
        assert!(c.deleted.contains(&"dnd_root".to_string()) && c.updated.is_empty());
        cfg.hidden_drives.clear();
        cfg.keep_downloaded = true;
        std::thread::sleep(std::time::Duration::from_millis(20));
        crate::disk::engine::write_config(dir.path(), &cfg).unwrap();
        assert!(e.children(ROOT_ID).unwrap()[0].keep_downloaded);
        assert!(!e.children("dnd_root").unwrap()[0].keep_downloaded, "only drive roots carry it; the rest inherit");
    }).await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn offline_is_transient_and_keeps_the_partial_download() {
    let s = MockServer::start().await;
    let uri = s.uri();
    tokio::task::spawn_blocking(move || {
        let dir = tempfile::tempdir().unwrap();
        let cfg = DiskConfig { api_base: format!("{uri}/api/v1"), org: "org_a".into(), token: "t".into(), ..Default::default() };
        let e = DiskEngine::with_config(dir.path(), cfg).unwrap();
        // Nothing mounted: the mock answers 404 for pull, which is not "offline".
        assert!(matches!(e.sync(), Err(DiskError::NotFound)));
        assert!(e.status().last_error.is_some());
    }).await.unwrap();
    drop(s);
    tokio::task::spawn_blocking(|| {
        let dir = tempfile::tempdir().unwrap();
        let cfg = DiskConfig { api_base: "http://127.0.0.1:9/api/v1".into(), org: "org_a".into(), token: "t".into(), ..Default::default() };
        let e = DiskEngine::with_config(dir.path(), cfg).unwrap();
        let err = e.sync().unwrap_err();
        assert!(err.is_transient(), "{err:?}");
    }).await.unwrap();
}

mod sealed_roundtrip {
    use super::*;
    use crate::disk::sealed as x;
    use base64::Engine as _;
    use std::io::Cursor;

    const B64: base64::engine::general_purpose::GeneralPurpose = base64::engine::general_purpose::STANDARD;

    #[tokio::test(flavor = "multi_thread")]
    async fn sealed_names_open_downloads_decrypt_and_uploads_seal() {
        // An identity, a scope key granted to it, and a sealed file under the scope.
        let secret: [u8; 32] = rand::random();
        let public = crypto_box::SecretKey::from(secret).public_key();
        let ks = x::new_key();
        let grant = public.seal(&mut crypto_box::aead::OsRng, ks.as_ref()).unwrap();
        let sk = x::ScopeKeys::derive(&ks);
        let kv = x::new_key();
        let prefix = x::new_prefix();
        let mut obj = Vec::new();
        let manifest = x::ChunkSealer::new(&kv, prefix, 4).seal("dnd_sf", "dvr_s1", Cursor::new(b"top secret"), &mut obj).unwrap();
        let vk = x::VersionKeys::derive(&kv);
        let sealed_file = json!({
            "id": "dnd_sf", "parent_id": "dnd_scope", "drive": "share_x", "kind": "file", "name": null, "sealed": true,
            "metadata_ciphertext": B64.encode(x::seal_meta(&sk.m, "dnd_sf", "Plan.pdf", Some("application/pdf")).unwrap()),
            "key_epoch": 1, "seal_scope_id": "dnd_scope", "size_bytes": obj.len(), "change_seq": 3, "can_write": true,
            "current_version": { "id": "dvr_s1", "size_bytes": obj.len(), "key_epoch": 1,
                "wrapped_key": B64.encode(x::wrap_version_key(&sk.w, "dnd_sf", "dvr_s1", &kv).unwrap()),
                "manifest_ciphertext": B64.encode(x::seal_manifest(&vk.f, &manifest).unwrap()) },
        });
        let scope_root = json!({ "id": "dnd_scope", "parent_id": null, "drive": "share_x", "share_name": "Board", "kind": "folder",
            "sealed": true, "seal_scope_id": "dnd_scope", "change_seq": 2, "can_write": true });

        let s = MockServer::start().await;
        Mock::given(method("GET")).and(path(format!("{BASE}/sync/pull")))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "cursor": "1.0", "nodes": [scope_root, sealed_file.clone()] })))
            .mount(&s).await;
        Mock::given(method("GET")).and(path(format!("{BASE}/scopes/dnd_scope")))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "scope": { "id": "dnd_scope", "epoch": 1,
                "grants": [{ "epoch": 1, "sealed_key": B64.encode(&grant) }], "epochs": [] } })))
            .mount(&s).await;
        Mock::given(method("GET")).and(path(format!("{BASE}/versions/dvr_s1/download")))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "download": { "url": format!("{}/blob/s1", s.uri()) } })))
            .mount(&s).await;
        Mock::given(method("GET")).and(path("/blob/s1")).respond_with(ResponseTemplate::new(200).set_body_bytes(obj.clone())).mount(&s).await;
        Mock::given(method("POST")).and(path(format!("{BASE}/uploads")))
            .respond_with(ResponseTemplate::new(201).set_body_json(json!({ "upload": { "id": "dup_s", "state": "reserved",
                "part_bytes": 8388608, "part_count": 1, "node_id": "dnd_up", "version_id": "dvr_up", "key_epoch": 1, "chunk_bytes": 4194304 } })))
            .mount(&s).await;
        Mock::given(method("POST")).and(path(format!("{BASE}/uploads/dup_s/parts")))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "parts": [{ "number": 1, "url": format!("{}/put/s", s.uri()) }] })))
            .mount(&s).await;
        Mock::given(method("PUT")).and(path("/put/s")).respond_with(ResponseTemplate::new(200)).mount(&s).await;
        Mock::given(method("POST")).and(path(format!("{BASE}/uploads/dup_s/complete")))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "node": sealed_file.clone() }))).mount(&s).await;
        Mock::given(method("GET")).and(path(format!("{BASE}/sync/nodes")))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "nodes": [sealed_file] }))).mount(&s).await;

        let uri = s.uri();
        let secret_b64 = B64.encode(secret);
        let (puts, reserve) = tokio::task::spawn_blocking(move || {
            let dir = tempfile::tempdir().unwrap();
            let cfg = DiskConfig { api_base: format!("{uri}/api/v1"), org: "org_a".into(), token: "t".into(),
                identity_secret: Some(secret_b64), ..Default::default() };
            let e = DiskEngine::with_config(dir.path(), cfg.clone()).unwrap();
            e.sync().unwrap();
            assert_eq!(e.children(ROOT_ID).unwrap()[0].filename, "Board");
            let f = &e.children("dnd_scope").unwrap()[0];
            assert_eq!(f.filename, "Plan.pdf");
            assert_eq!(f.size, 10, "plaintext size comes from the manifest");
            assert!(!f.locked);
            assert_eq!(std::fs::read(e.fetch("dnd_sf", &NoProgress).unwrap()).unwrap(), b"top secret");

            let src = dir.path().join("Plan.pdf");
            std::fs::write(&src, b"new secret text").unwrap();
            e.create_file("dnd_scope", "Plan.pdf", &src, "op1", &NoProgress).unwrap();

            // Without the identity (FileVault off) the same tree reads as locked.
            let dir2 = tempfile::tempdir().unwrap();
            let locked = DiskEngine::with_config(dir2.path(), DiskConfig { identity_secret: None, ..cfg }).unwrap();
            locked.sync().unwrap();
            let l = &locked.children("dnd_scope").unwrap()[0];
            assert!(l.locked && !l.can_write);
            assert!(matches!(locked.fetch("dnd_sf", &NoProgress), Err(DiskError::Locked)));
            ((), ())
        }).await.unwrap();
        let _ = (puts, reserve);

        let reqs = s.received_requests().await.unwrap();
        let reserve: serde_json::Value = reqs.iter().find(|r| r.url.path().ends_with("/uploads") && r.method.as_str() == "POST").unwrap().body_json().unwrap();
        assert_eq!(reserve["sealed"], true);
        assert!(reserve.get("name").is_none(), "a sealed name never reaches the server");
        let meta = x::open_meta(&sk.m, reserve["id"].as_str().unwrap(), &B64.decode(reserve["metadata_ciphertext"].as_str().unwrap()).unwrap()).unwrap();
        assert_eq!(meta.name, "Plan (1).pdf", "a clash in a sealed folder gets a free name on this Mac");
        let complete: serde_json::Value = reqs.iter().find(|r| r.url.path().ends_with("/complete")).unwrap().body_json().unwrap();
        let up_kv = x::unwrap_version_key(&sk.w, "dnd_up", "dvr_up", &B64.decode(complete["wrapped_key"].as_str().unwrap()).unwrap()).unwrap();
        let up_manifest = x::open_manifest(&x::VersionKeys::derive(&up_kv).f, "dnd_up", "dvr_up",
            &B64.decode(complete["manifest_ciphertext"].as_str().unwrap()).unwrap()).unwrap();
        let body = &reqs.iter().find(|r| r.url.path() == "/put/s").unwrap().body;
        let mut plain = Vec::new();
        x::ChunkOpener::new(&up_kv, up_manifest).unwrap().open(Cursor::new(body), &mut plain).unwrap();
        assert_eq!(plain, b"new secret text");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_dropped_upload_resumes_with_only_the_missing_part() {
    let s = MockServer::start().await;
    let root = node("dnd_root", None, "folder", "", None, 1);
    Mock::given(method("GET")).and(path(format!("{BASE}/sync/pull")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "cursor": "1.0", "nodes": [root] }))).mount(&s).await;
    Mock::given(method("POST")).and(path(format!("{BASE}/uploads")))
        .respond_with(ResponseTemplate::new(201).set_body_json(json!({ "upload": {
            "id": "dup_r", "state": "reserved", "part_bytes": 4, "part_count": 2, "node_id": "dnd_r" } })))
        .expect(1).mount(&s).await;
    Mock::given(method("POST")).and(path(format!("{BASE}/uploads/dup_r/parts")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "parts": [
            { "number": 1, "url": format!("{}/put/1", s.uri()) }, { "number": 2, "url": format!("{}/put/2", s.uri()) } ] })))
        .mount(&s).await;
    Mock::given(method("PUT")).and(path("/put/1")).respond_with(ResponseTemplate::new(200)).expect(1).mount(&s).await;
    // Part 2 fails three times (one request's retries), then storage is back.
    Mock::given(method("PUT")).and(path("/put/2")).respond_with(ResponseTemplate::new(503)).up_to_n_times(3).with_priority(1).mount(&s).await;
    Mock::given(method("PUT")).and(path("/put/2")).respond_with(ResponseTemplate::new(200)).with_priority(5).mount(&s).await;
    Mock::given(method("GET")).and(path(format!("{BASE}/uploads/dup_r")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "upload": { "id": "dup_r", "state": "reserved", "part_bytes": 4, "part_count": 2, "node_id": "dnd_r" },
            "parts": [{ "number": 1, "size_bytes": 4 }] })))
        .mount(&s).await;
    Mock::given(method("POST")).and(path(format!("{BASE}/uploads/dup_r/complete")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "node": node("dnd_r", Some("dnd_root"), "file", "r.bin", Some(("dvr_r", 6)), 4) })))
        .mount(&s).await;
    Mock::given(method("GET")).and(path(format!("{BASE}/sync/nodes")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "nodes": [node("dnd_r", Some("dnd_root"), "file", "r.bin", Some(("dvr_r", 6)), 4)] })))
        .mount(&s).await;
    let uri = s.uri();
    tokio::task::spawn_blocking(move || {
        let dir = tempfile::tempdir().unwrap();
        let cfg = DiskConfig { api_base: format!("{uri}/api/v1"), org: "org_a".into(), token: "t".into(), ..Default::default() };
        let e = DiskEngine::with_config(dir.path(), cfg).unwrap();
        e.sync().unwrap();
        let src = dir.path().join("r.bin");
        std::fs::write(&src, b"abcdef").unwrap();
        let first = e.create_file("dnd_root", "r.bin", &src, "op1", &NoProgress).unwrap_err();
        assert!(first.is_transient(), "{first:?}: macOS keeps the change and calls again");
        assert_eq!(e.status().uploading, 1);
        // macOS calls again (a restart in between changes nothing: the state is in disk.db).
        let e = DiskEngine::open_with(dir.path(), e.config_for_test()).unwrap();
        assert_eq!(e.create_file("dnd_root", "r.bin", &src, "op1", &NoProgress).unwrap().id, "dnd_r");
        assert_eq!(e.status().uploading, 0);
    }).await.unwrap();
    // `expect(1)` on reserve and on part 1: the retry reused the reservation and skipped the stored part.
}

#[tokio::test(flavor = "multi_thread")]
async fn a_finished_partial_download_finalizes_without_asking_storage() {
    let s = MockServer::start().await;
    let root = node("dnd_root", None, "folder", "", None, 1);
    let file = node("dnd_f", Some("dnd_root"), "file", "a.txt", Some(("dvr_1", 5)), 2);
    Mock::given(method("GET")).and(path(format!("{BASE}/sync/pull")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "cursor": "1.0", "nodes": [root, file] }))).mount(&s).await;
    Mock::given(method("GET")).and(path(format!("{BASE}/versions/dvr_1/download"))).respond_with(ResponseTemplate::new(500)).expect(0).mount(&s).await;
    let uri = s.uri();
    tokio::task::spawn_blocking(move || {
        let dir = tempfile::tempdir().unwrap();
        let cfg = DiskConfig { api_base: format!("{uri}/api/v1"), org: "org_a".into(), token: "t".into(), ..Default::default() };
        let e = DiskEngine::with_config(dir.path(), cfg).unwrap();
        e.sync().unwrap();
        std::fs::create_dir_all(dir.path().join("staging")).unwrap();
        std::fs::write(dir.path().join("staging/dvr_1.part"), b"hello").unwrap();
        assert_eq!(std::fs::read(e.fetch("dnd_f", &NoProgress).unwrap()).unwrap(), b"hello");
    }).await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_lost_completion_answer_finishes_on_retry() {
    let s = MockServer::start().await;
    let root = node("dnd_root", None, "folder", "", None, 1);
    let done = node("dnd_d", Some("dnd_root"), "file", "d.txt", Some(("dvr_d", 3)), 3);
    Mock::given(method("GET")).and(path(format!("{BASE}/sync/pull")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "cursor": "1.0", "nodes": [root] }))).mount(&s).await;
    // The reservation the same idempotency key hands back is already done.
    Mock::given(method("POST")).and(path(format!("{BASE}/uploads")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "upload": {
            "id": "dup_d", "state": "done", "part_bytes": 8388608, "part_count": 1, "node_id": "dnd_d" } })))
        .mount(&s).await;
    Mock::given(method("POST")).and(path(format!("{BASE}/uploads/dup_d/parts"))).respond_with(ResponseTemplate::new(409)).expect(0).mount(&s).await;
    Mock::given(method("GET")).and(path(format!("{BASE}/sync/nodes")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "nodes": [done] }))).mount(&s).await;
    let uri = s.uri();
    tokio::task::spawn_blocking(move || {
        let dir = tempfile::tempdir().unwrap();
        let cfg = DiskConfig { api_base: format!("{uri}/api/v1"), org: "org_a".into(), token: "t".into(), ..Default::default() };
        let e = DiskEngine::with_config(dir.path(), cfg).unwrap();
        e.sync().unwrap();
        let src = dir.path().join("d.txt");
        std::fs::write(&src, b"abc").unwrap();
        assert_eq!(e.create_file("dnd_root", "d.txt", &src, "op1", &NoProgress).unwrap().id, "dnd_d");
        assert_eq!(e.status().uploading, 0);
    }).await.unwrap();
}
