//! kona-check: prints what the kona-client registry knows about one chain id.
//!
//! The probe is built against the `kona-registry` crate of the monorepo checkout that the
//! Kona prestate is built from, with `KONA_CUSTOM_CONFIGS=true` and `KONA_CUSTOM_CONFIGS_DIR`
//! pointing at the files `drill/kona-configs.sh` produced. The crate's build script merges and
//! validates the custom files exactly as the prestate build does, and the lazy statics below are
//! the ones the client consults at boot (`ROLLUP_CONFIGS.get(&chain_id)`). Printing them shows the
//! rollup configuration the client inside the VM will use for the chain, before any VM is built.
//!
//! Usage: kona-check <chain id>   (exit 0: the chain is embedded; 3: it is not)

use kona_registry::{CHAINS, DEPENDENCY_SETS, OPCHAINS, ROLLUP_CONFIGS};

fn main() {
    let arg = std::env::args().nth(1).unwrap_or_default();
    let chain_id: u64 = match arg.parse() {
        Ok(id) => id,
        Err(_) => {
            eprintln!("usage: kona-check <chain id>");
            std::process::exit(2);
        }
    };
    let chain = CHAINS.get_chain_by_id(chain_id);
    let chain_config = OPCHAINS.get(&chain_id);
    let rollup_config = ROLLUP_CONFIGS.get(&chain_id);
    let depset = DEPENDENCY_SETS.get(&chain_id);
    let out = serde_json::json!({
        "chainId": chain_id,
        "embedded": rollup_config.is_some(),
        "registryChains": CHAINS.len(),
        "customConfigs": option_env!("KONA_CUSTOM_CONFIGS").unwrap_or("false") == "true",
        "customConfigsDir": option_env!("KONA_CUSTOM_CONFIGS_DIR"),
        "chain": chain,
        "chainConfig": chain_config,
        "rollupConfig": rollup_config,
        "dependencySet": depset,
    });
    println!("{}", serde_json::to_string_pretty(&out).expect("serialize"));
    if rollup_config.is_none() {
        std::process::exit(3);
    }
}
