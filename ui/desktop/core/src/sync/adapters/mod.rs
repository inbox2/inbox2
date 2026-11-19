pub mod gmail_labels;
pub mod gmail_mail;
pub mod imap_adapter;
pub mod meta;
pub mod microsoft_mail;
pub(crate) mod util;

pub use gmail_mail::GmailAdapter;
pub use imap_adapter::{ImapAdapter, ImapConfig};
pub use meta::MetaAdapter;
pub use microsoft_mail::MicrosoftAdapter;

use std::sync::Arc;

use tokio::sync::RwLock;

use crate::sync::model::{ApiContext, MetaCredentials, ProviderCredentials, ProviderType};
use crate::sync::oauth::TokenManager;
use crate::sync::provider::ProviderAdapter;
use crate::sync::store::SyncStore;

/// Create an adapter for the given provider type.
///
/// IMAP ignores the OAuth plumbing; Gmail/Microsoft build a `TokenManager` from
/// the stored credentials + API context so they can refresh tokens via the proxy.
pub fn create_adapter(
    account_key: &str,
    provider_type: &ProviderType,
    host: &str,
    port: u16,
    use_tls: bool,
    credentials: &ProviderCredentials,
    store: Arc<SyncStore>,
    api_context: Arc<RwLock<Option<ApiContext>>>,
) -> Box<dyn ProviderAdapter> {
    match provider_type {
        ProviderType::Imap => Box::new(ImapAdapter::new(ImapConfig {
            host: host.to_string(),
            port,
            use_tls,
            ..ImapConfig::default()
        })),
        ProviderType::Gmail => {
            let token = Arc::new(TokenManager::new(
                account_key.to_string(),
                ProviderType::Gmail,
                store.clone(),
                api_context,
                credentials,
            ));
            Box::new(GmailAdapter::new(token, store, account_key.to_string()))
        }
        ProviderType::Microsoft => {
            let token = Arc::new(TokenManager::new(
                account_key.to_string(),
                ProviderType::Microsoft,
                store.clone(),
                api_context,
                credentials,
            ));
            Box::new(MicrosoftAdapter::new(token, store, account_key.to_string()))
        }
        ProviderType::Instagram | ProviderType::Messenger | ProviderType::WhatsApp => {
            // One MetaAdapter implementation, switched by channel. Meta creds are
            // the BYOK app-secret bundle + asset IDs; a non-Meta credential here
            // is a wiring bug — fall back to an empty bundle (connect() then
            // fails cleanly with "missing System User token").
            let channel = provider_type
                .meta_channel()
                .expect("meta provider type has a channel");
            let meta_creds = match credentials {
                ProviderCredentials::Meta(m) => m.clone(),
                _ => MetaCredentials::default(),
            };
            Box::new(MetaAdapter::new(
                channel,
                meta_creds,
                store,
                account_key.to_string(),
            ))
        }
    }
}
