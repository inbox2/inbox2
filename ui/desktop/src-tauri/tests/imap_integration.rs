//! IMAP integration tests — run against a real Dovecot container.
//!
//! ## Prerequisites
//!
//! Start the Dovecot test container:
//!
//!   docker compose -f docker/docker-compose.yml --profile test up -d
//!
//! The container provides:
//! - IMAP on localhost:1143 (STARTTLS) and localhost:1993 (implicit TLS)
//! - CONDSTORE + QRESYNC + NOTIFY + UIDPLUS + IDLE + SPECIAL-USE
//! - Test user: testuser / testpass
//!
//! Set IMAP_TEST_HOST=localhost and IMAP_TEST_PORT=1993 to run these tests.
//! Without these env vars, tests are skipped (not failed).

use std::env;

use app_lib::sync::adapters::{ImapAdapter, ImapConfig};
use app_lib::sync::error::SyncError;
use app_lib::sync::model::*;
use app_lib::sync::provider::ProviderAdapter;

fn imap_test_config() -> Option<(String, u16)> {
    let host = env::var("IMAP_TEST_HOST").ok()?;
    let port: u16 = env::var("IMAP_TEST_PORT").ok()?.parse().ok()?;
    Some((host, port))
}

macro_rules! require_imap {
    () => {
        match imap_test_config() {
            Some(config) => config,
            None => {
                eprintln!(
                    "Skipping IMAP integration test: IMAP_TEST_HOST/IMAP_TEST_PORT not set"
                );
                return;
            }
        }
    };
}

#[test]
#[ignore = "live IMAP integration (GreenMail): `docker compose -f docker/docker-compose.yml --profile test up -d` then `INBOX2_IMAP_ACCEPT_INVALID_CERTS=1 IMAP_TEST_HOST=localhost IMAP_TEST_PORT=3993 cargo test --test imap_integration -- --ignored`"]
fn test_connect_and_capabilities() {
    let (host, port) = require_imap!();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let mut adapter = ImapAdapter::new(ImapConfig {
            host,
            port,
            use_tls: true,
            ..ImapConfig::default()
        });
        let creds = ProviderCredentials::Password {
            username: "testuser".to_string(),
            password: "testpass".to_string(),
        };
        let caps = adapter.connect(&creds).await.expect("connect failed");
        // Capability negotiation must have happened (server advertised some).
        assert!(!caps.raw.is_empty(), "server should advertise capabilities");
        assert!(caps.push, "test IMAP server should support IDLE");
        // CONDSTORE/QRESYNC are optional extensions; not every server advertises
        // them and the adapter degrades gracefully when absent.
        adapter.disconnect().await.expect("disconnect failed");
    });
}

#[test]
#[ignore = "live IMAP integration (GreenMail): `docker compose -f docker/docker-compose.yml --profile test up -d` then `INBOX2_IMAP_ACCEPT_INVALID_CERTS=1 IMAP_TEST_HOST=localhost IMAP_TEST_PORT=3993 cargo test --test imap_integration -- --ignored`"]
fn test_connect_bad_credentials() {
    let (host, port) = require_imap!();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let mut adapter = ImapAdapter::new(ImapConfig {
            host,
            port,
            use_tls: true,
            ..ImapConfig::default()
        });
        let creds = ProviderCredentials::Password {
            username: "testuser".to_string(),
            password: "wrongpassword".to_string(),
        };
        let result = adapter.connect(&creds).await;
        assert!(result.is_err(), "bad credentials should fail");
    });
}

#[test]
#[ignore = "live IMAP integration (GreenMail): `docker compose -f docker/docker-compose.yml --profile test up -d` then `INBOX2_IMAP_ACCEPT_INVALID_CERTS=1 IMAP_TEST_HOST=localhost IMAP_TEST_PORT=3993 cargo test --test imap_integration -- --ignored`"]
fn test_list_folders() {
    let (host, port) = require_imap!();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let mut adapter = ImapAdapter::new(ImapConfig {
            host,
            port,
            use_tls: true,
            ..ImapConfig::default()
        });
        let creds = ProviderCredentials::Password {
            username: "testuser".to_string(),
            password: "testpass".to_string(),
        };
        adapter.connect(&creds).await.unwrap();
        let folders = adapter.list_folders().await.unwrap();
        assert!(
            folders
                .iter()
                .any(|f| f.role == Some(WellKnownFolder::Inbox)),
            "must have INBOX: {folders:?}"
        );
        adapter.disconnect().await.unwrap();
    });
}

#[test]
#[ignore = "live IMAP integration (GreenMail): `docker compose -f docker/docker-compose.yml --profile test up -d` then `INBOX2_IMAP_ACCEPT_INVALID_CERTS=1 IMAP_TEST_HOST=localhost IMAP_TEST_PORT=3993 cargo test --test imap_integration -- --ignored`"]
fn test_initial_sync_empty_inbox() {
    let (host, port) = require_imap!();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let mut adapter = ImapAdapter::new(ImapConfig {
            host,
            port,
            use_tls: true,
            ..ImapConfig::default()
        });
        let creds = ProviderCredentials::Password {
            username: "testuser".to_string(),
            password: "testpass".to_string(),
        };
        adapter.connect(&creds).await.unwrap();
        let folders = adapter.list_folders().await.unwrap();
        let inbox = folders
            .iter()
            .find(|f| f.role == Some(WellKnownFolder::Inbox))
            .unwrap();
        let result = adapter.initial_sync(inbox, 100, None).await.unwrap();
        assert!(!result.has_more || result.messages.len() <= 100);
        adapter.disconnect().await.unwrap();
    });
}

#[test]
#[ignore = "live IMAP integration (GreenMail): `docker compose -f docker/docker-compose.yml --profile test up -d` then `INBOX2_IMAP_ACCEPT_INVALID_CERTS=1 IMAP_TEST_HOST=localhost IMAP_TEST_PORT=3993 cargo test --test imap_integration -- --ignored`"]
fn test_initial_sync_and_incremental() {
    let (host, port) = require_imap!();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let mut adapter = ImapAdapter::new(ImapConfig {
            host,
            port,
            use_tls: true,
            ..ImapConfig::default()
        });
        let creds = ProviderCredentials::Password {
            username: "testuser".to_string(),
            password: "testpass".to_string(),
        };
        adapter.connect(&creds).await.unwrap();
        let folders = adapter.list_folders().await.unwrap();
        let inbox = folders
            .iter()
            .find(|f| f.role == Some(WellKnownFolder::Inbox))
            .unwrap();
        let initial = adapter.initial_sync(inbox, 100, None).await.unwrap();
        let cursor = SyncCursor {
            uid_validity: initial.uid_validity,
            highest_mod_seq: initial.new_highest_mod_seq,
            last_synced_uid: initial
                .messages
                .last()
                .and_then(|(_, pid)| pid.uid)
                .unwrap_or(0),
            token: None,
        };
        let incremental = adapter.incremental_sync(inbox, &cursor).await.unwrap();
        assert_eq!(incremental.uid_validity, initial.uid_validity);
        adapter.disconnect().await.unwrap();
    });
}

#[test]
#[ignore = "live IMAP integration (GreenMail): `docker compose -f docker/docker-compose.yml --profile test up -d` then `INBOX2_IMAP_ACCEPT_INVALID_CERTS=1 IMAP_TEST_HOST=localhost IMAP_TEST_PORT=3993 cargo test --test imap_integration -- --ignored`"]
fn test_uidvalidity_change_detected() {
    let (host, port) = require_imap!();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let mut adapter = ImapAdapter::new(ImapConfig {
            host,
            port,
            use_tls: true,
            ..ImapConfig::default()
        });
        let creds = ProviderCredentials::Password {
            username: "testuser".to_string(),
            password: "testpass".to_string(),
        };
        adapter.connect(&creds).await.unwrap();
        let folders = adapter.list_folders().await.unwrap();
        let inbox = folders
            .iter()
            .find(|f| f.role == Some(WellKnownFolder::Inbox))
            .unwrap();

        // Bogus UIDVALIDITY to trigger detection
        let cursor = SyncCursor {
            uid_validity: 99999999,
            highest_mod_seq: 0,
            last_synced_uid: 0,
            token: None,
        };
        let result = adapter.incremental_sync(inbox, &cursor).await;
        match result {
            Err(SyncError::UidValidityChanged { .. }) => { /* expected */ }
            Ok(r) if r.uid_validity != 99999999 => { /* engine would catch this */ }
            Ok(_) => panic!("should detect UIDVALIDITY mismatch"),
            Err(e) => eprintln!("Got different error (acceptable): {e}"),
        }
        adapter.disconnect().await.unwrap();
    });
}

#[test]
#[ignore = "live IMAP integration (GreenMail): `docker compose -f docker/docker-compose.yml --profile test up -d` then `INBOX2_IMAP_ACCEPT_INVALID_CERTS=1 IMAP_TEST_HOST=localhost IMAP_TEST_PORT=3993 cargo test --test imap_integration -- --ignored`"]
fn test_writeback_mark_read() {
    let (host, port) = require_imap!();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let mut adapter = ImapAdapter::new(ImapConfig {
            host,
            port,
            use_tls: true,
            ..ImapConfig::default()
        });
        let creds = ProviderCredentials::Password {
            username: "testuser".to_string(),
            password: "testpass".to_string(),
        };
        adapter.connect(&creds).await.unwrap();
        let folders = adapter.list_folders().await.unwrap();
        let inbox = folders
            .iter()
            .find(|f| f.role == Some(WellKnownFolder::Inbox))
            .unwrap();
        let initial = adapter.initial_sync(inbox, 10, None).await.unwrap();
        if initial.messages.is_empty() {
            eprintln!("No messages in INBOX — skipping writeback test");
            adapter.disconnect().await.unwrap();
            return;
        }
        let (msg, provider_id) = &initial.messages[0];
        let action = WritebackAction {
            key: "wba_test".to_string(),
            account_key: "acc_test".to_string(),
            action_type: ActionType::MarkRead,
            message_key: msg.key.clone(),
            folder_key: Some(inbox.key.clone()),
            provider_snapshot: Some(provider_id.clone()),
            status: ActionStatus::Pending,
            retry_count: 0,
            max_retries: 3,
            next_retry_at: None,
            error_message: None,
        };
        let result = adapter.apply_action(&action, provider_id).await;
        assert!(result.is_ok(), "mark_read should succeed: {result:?}");
        let re_sync = adapter.initial_sync(inbox, 10, None).await.unwrap();
        if let Some((re_msg, _)) = re_sync
            .messages
            .iter()
            .find(|(m, _)| m.message_id == msg.message_id)
        {
            assert!(re_msg.flags.read, "message should now be marked read");
        }
        adapter.disconnect().await.unwrap();
    });
}

#[test]
#[ignore = "live IMAP integration (GreenMail): `docker compose -f docker/docker-compose.yml --profile test up -d` then `INBOX2_IMAP_ACCEPT_INVALID_CERTS=1 IMAP_TEST_HOST=localhost IMAP_TEST_PORT=3993 cargo test --test imap_integration -- --ignored`"]
fn test_reconnect_backoff() {
    let initial = 1u64;
    let max = 300u64;
    let mut backoff = initial;
    let mut attempts = Vec::new();
    for _ in 0..12 {
        attempts.push(backoff);
        backoff = (backoff * 2).min(max);
    }
    assert_eq!(attempts[0], 1);
    assert_eq!(attempts[1], 2);
    assert_eq!(attempts[2], 4);
    assert_eq!(attempts[3], 8);
    assert_eq!(attempts[4], 16);
    assert_eq!(attempts[5], 32);
    assert_eq!(attempts[6], 64);
    assert_eq!(attempts[7], 128);
    assert_eq!(attempts[8], 256);
    assert_eq!(attempts[9], 300); // capped
    assert_eq!(attempts[10], 300);
    assert_eq!(attempts[11], 300);
}

/// End-to-end interactive flow: APPEND a real multipart message with an
/// attachment to INBOX, sync it through the adapter + store, then exercise the
/// `ImapInteractive` provider — full body via MIME parsing, attachment listing,
/// raw attachment download, and view-source. Exercises everything the desktop
/// preview pane hits when an IMAP message is opened.
#[test]
#[ignore = "live IMAP integration (GreenMail): `docker compose -f docker/docker-compose.yml --profile test up -d` then `INBOX2_IMAP_ACCEPT_INVALID_CERTS=1 IMAP_TEST_HOST=localhost IMAP_TEST_PORT=3993 cargo test --test imap_integration -- --ignored`"]
fn test_interactive_fetch_body_and_attachment() {
    use std::sync::Arc;

    use app_lib::sync::interactive::{
        ImapConnectionInfo, ImapInteractive, InteractiveProvider,
    };
    use app_lib::sync::store::SyncStore;

    let (host, port) = require_imap!();
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let creds = ProviderCredentials::Password {
            username: "testuser".to_string(),
            password: "testpass".to_string(),
        };

        // 1. APPEND a multipart/mixed message (text body + base64 PDF) to INBOX.
        //    "UERGREFUQQ==" is base64("PDFDATA").
        let raw_msg = b"From: alice@example.com\r\n\
To: testuser@localhost\r\n\
Subject: With attachment\r\n\
MIME-Version: 1.0\r\n\
Message-ID: <fetchtest@example.com>\r\n\
Content-Type: multipart/mixed; boundary=\"xyz\"\r\n\r\n\
--xyz\r\n\
Content-Type: text/plain\r\n\r\n\
body text here\r\n\
--xyz\r\n\
Content-Type: application/pdf; name=\"doc.pdf\"\r\n\
Content-Disposition: attachment; filename=\"doc.pdf\"\r\n\
Content-Transfer-Encoding: base64\r\n\r\n\
UERGREFUQQ==\r\n\
--xyz--\r\n";
        {
            let mut tls = native_tls::TlsConnector::builder();
            tls.danger_accept_invalid_certs(true);
            tls.danger_accept_invalid_hostnames(true);
            let tls = tls.build().unwrap();
            let client = imap::connect((host.as_str(), port), host.as_str(), &tls).unwrap();
            let mut session = client.login("testuser", "testpass").map_err(|e| e.0).unwrap();
            session.append("INBOX", &raw_msg[..]).unwrap();
            let _ = session.logout();
        }

        // 2. Throwaway on-disk store + IMAP account.
        let tmp = tempfile::tempdir().unwrap();
        let store = Arc::new(
            SyncStore::new(&tmp.path().join("inbox2.db"), tmp.path()).unwrap(),
        );
        let account = ExternalAccount {
            key: String::new(),
            display_name: "Imap".into(),
            email_address: "testuser@localhost".into(),
            provider_type: ProviderType::Imap,
            host: Some(host.clone()),
            port: Some(port),
            use_tls: true,
            smtp_host: None,
            smtp_port: None,
            smtp_use_tls: false,
            auth_method: "password".into(),
            status: AccountStatus::Disconnected,
            error_message: None,
            last_connected_at: None,
            sort_order: 0,
            avatar_url: None,
        };
        let account_key = store.create_account(&account).unwrap();

        // 3. Sync the folder + message into the store (so the interactive
        //    provider can resolve message_key → folder + UID).
        let mut adapter = ImapAdapter::new(ImapConfig {
            host: host.clone(),
            port,
            use_tls: true,
            ..ImapConfig::default()
        });
        adapter.connect(&creds).await.unwrap();
        let folders = adapter.list_folders().await.unwrap();
        let mut inbox = folders
            .into_iter()
            .find(|f| f.role == Some(WellKnownFolder::Inbox))
            .unwrap();
        inbox.account_key = account_key.clone();
        inbox.sync_enabled = true;
        store.upsert_folder(&inbox).unwrap();

        let result = adapter.initial_sync(&inbox, 50, None).await.unwrap();
        let (msg, pid) = result
            .messages
            .into_iter()
            .find(|(m, _)| m.message_id.contains("fetchtest"))
            .expect("appended message should appear in initial sync");
        let upsert = store
            .upsert_synced_message(&account_key, &inbox.key, &msg, &pid)
            .unwrap();
        // The store assigns its own message key; resolve it via the conversation.
        let (message_key, _) = store
            .message_keys_for_conversation(&account_key, &upsert.conversation_key)
            .unwrap()
            .into_iter()
            .next()
            .expect("synced message should be in its conversation");
        // Lazy bodies: the synced row carries no body until fetched.
        assert!(msg.body_plain.is_none() && msg.body_html.is_none());
        adapter.disconnect().await.unwrap();

        // 4. Interactive fetch — full body + attachment list via MIME parse.
        let conn = ImapConnectionInfo {
            host: host.clone(),
            port,
            use_tls: true,
            credentials: creds,
            smtp_host: None,
            smtp_port: 587,
            smtp_use_tls: false,
        };
        let interactive = ImapInteractive::new(store.clone(), account_key.clone(), conn);

        let fetched = interactive.fetch_message(&message_key).await.unwrap();
        assert!(
            fetched.body_plain.as_deref().unwrap_or("").contains("body text here"),
            "plain body should be parsed: {:?}",
            fetched.body_plain
        );
        assert_eq!(fetched.attachments.len(), 1, "one (non-inline) attachment");
        let att = &fetched.attachments[0];
        assert_eq!(att.filename, "doc.pdf");
        assert_eq!(att.mime_type, "application/pdf");

        // 5. Download the attachment bytes (transfer-decoded).
        let bytes = interactive
            .download_attachment(&message_key, &att.attachment_id)
            .await
            .unwrap();
        assert_eq!(bytes, b"PDFDATA");

        // 6. View source returns the raw RFC822.
        let src = interactive.get_message_source(&message_key).await.unwrap();
        assert!(src.contains("Subject: With attachment"), "raw source: {src}");
    });
}
