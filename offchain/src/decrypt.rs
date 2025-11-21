use crate::eth::EncryptedOrderEvent;
use crate::oracle::PlaintextOrder;
use anyhow::Result;
use ethers::types::U256;
use tracing::warn;

#[derive(Default, Clone)]
pub struct Decryptor;

impl Decryptor {
    pub async fn decrypt(&self, event: &EncryptedOrderEvent) -> Result<Option<PlaintextOrder>> {
        warn!(
            "Decryptor not implemented yet, emitting placeholder plaintext for {:?}",
            event.order_hash
        );

        Ok(Some(PlaintextOrder {
            amount_in: U256::zero(),
            min_amount_out: U256::zero(),
            slippage_bps: 100,
            deadline: event.deadline,
        }))
    }
}
