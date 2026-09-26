use codex_core_api::{Config, ExtensionRegistryBuilder};
use codex_extension_api::ContextContributor;
use std::sync::Arc;

struct ShipiOSContext;
impl ContextContributor for ShipiOSContext {}

#[tokio::main]
async fn main() -> std::io::Result<()> {
    let root = tempfile::tempdir()?;
    let shipios_home = root.path().join("ShipiOS/Agent");
    let other_home = root.path().join("other-codex");
    std::fs::create_dir_all(&shipios_home)?;
    std::fs::create_dir_all(&other_home)?;

    // If the isolated loader reads either home config, this invalid TOML fails.
    std::fs::write(shipios_home.join("config.toml"), "invalid = [")?;
    std::fs::write(other_home.join("config.toml"), "invalid = [")?;

    let config = Config::load_default_with_cli_overrides_for_codex_home(
        shipios_home.clone(),
        vec![(
            "model".to_owned(),
            toml::Value::String("shipios-poc-model".to_owned()),
        )],
    )
    .await?;
    let other =
        Config::load_default_with_cli_overrides_for_codex_home(other_home.clone(), vec![]).await?;
    assert_eq!(config.codex_home.to_path_buf(), shipios_home);
    assert_eq!(other.codex_home.to_path_buf(), other_home);
    assert_eq!(config.model.as_deref(), Some("shipios-poc-model"));
    assert_ne!(config.model, other.model);

    let mut extensions = ExtensionRegistryBuilder::<Config>::new();
    extensions.prompt_contributor(Arc::new(ShipiOSContext));
    assert_eq!(extensions.build().context_contributors().len(), 1);
    println!("isolated Codex configuration and extension registry initialized");
    Ok(())
}
