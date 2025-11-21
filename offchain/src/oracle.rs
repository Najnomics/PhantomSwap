use crate::config::RelayerConfig;
use anyhow::{anyhow, Result};
use ethers::contract::abigen;
use ethers::middleware::SignerMiddleware;
use ethers::providers::{Provider, Http};
use ethers::signers::LocalWallet;
use ethers::types::{H256, TxHash, U256};
use std::sync::Arc;

abigen!(
    CurveOracleContract,
    r#"[
        function submitDecryption(bytes32 orderHash, tuple(uint256 amountIn, uint256 minAmountOut, uint16 slippageBps, uint64 deadline) data) external,
        event OrderSubmitted(bytes32 indexed orderHash),
        event OrderConsumed(bytes32 indexed orderHash)
    ]"#
);

pub struct OracleClient<M> {
    contract: CurveOracleContract<M>,
}

pub struct PlaintextOrder {
    pub amount_in: U256,
    pub min_amount_out: U256,
    pub slippage_bps: u16,
    pub deadline: u64,
}

impl OracleClient<Arc<SignerMiddleware<Provider<Http>, LocalWallet>>> {
    pub fn new(
        signer: Arc<SignerMiddleware<Provider<Http>, LocalWallet>>,
        config: &RelayerConfig,
    ) -> Result<Self> {
        let contract = CurveOracleContract::new(config.curve_oracle_address, signer);
        Ok(Self { contract })
    }

    pub async fn submit(&self, order_hash: H256, order: PlaintextOrder) -> Result<TxHash> {
        let pending = self
            .contract
            .submit_decryption(order_hash, order.into())
            .send()
            .await?;
        let receipt = pending.await?.ok_or_else(|| anyhow!("transaction reverted"))?;
        Ok(receipt.transaction_hash)
    }
}

// The abigen macro generates a struct for the tuple parameter
// The name is typically based on the function and parameter name
// For submitDecryption(bytes32, tuple(...) data), it generates SubmitDecryptionData
impl From<PlaintextOrder> for SubmitDecryptionData {
    fn from(order: PlaintextOrder) -> Self {
        SubmitDecryptionData {
            amount_in: order.amount_in,
            min_amount_out: order.min_amount_out,
            slippage_bps: order.slippage_bps,
            deadline: order.deadline,
        }
    }
}
