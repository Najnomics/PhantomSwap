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
        {
            "type": "function",
            "name": "submitDecryption",
            "inputs": [
                {
                    "name": "orderHash",
                    "type": "bytes32",
                    "internalType": "bytes32"
                },
                {
                    "name": "data",
                    "type": "tuple",
                    "internalType": "struct ICurveDecryptionOracle.DecryptedOrder",
                    "components": [
                        {
                            "name": "amountIn",
                            "type": "uint256",
                            "internalType": "uint256"
                        },
                        {
                            "name": "minAmountOut",
                            "type": "uint256",
                            "internalType": "uint256"
                        },
                        {
                            "name": "slippageBps",
                            "type": "uint16",
                            "internalType": "uint16"
                        },
                        {
                            "name": "deadline",
                            "type": "uint64",
                            "internalType": "uint64"
                        }
                    ]
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable"
        },
        {
            "type": "event",
            "name": "OrderSubmitted",
            "inputs": [
                {
                    "name": "orderHash",
                    "type": "bytes32",
                    "indexed": true,
                    "internalType": "bytes32"
                }
            ]
        },
        {
            "type": "event",
            "name": "OrderConsumed",
            "inputs": [
                {
                    "name": "orderHash",
                    "type": "bytes32",
                    "indexed": true,
                    "internalType": "bytes32"
                }
            ]
        }
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

impl From<PlaintextOrder> for DecryptedOrder {
    fn from(order: PlaintextOrder) -> Self {
        DecryptedOrder {
            amount_in: order.amount_in,
            min_amount_out: order.min_amount_out,
            slippage_bps: order.slippage_bps,
            deadline: order.deadline,
        }
    }
}
