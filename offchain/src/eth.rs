use crate::config::RelayerConfig;
use anyhow::Result;
use ethers::abi::RawLog;
use ethers::contract::{abigen, EthEvent};
use ethers::providers::{Middleware, Provider, Http};
use ethers::types::{Filter, H160, H256, Log, U64};
use std::sync::Arc;

abigen!(
    PhantomSwapContract,
    r#"[
        event OrderSubmitted(bytes32 indexed orderHash,address indexed owner,address indexed tokenIn,address tokenOut,uint64 deadline)
    ]"#,
    event_derives(serde::Deserialize, serde::Serialize)
);

pub struct PhantomSwapWatcher<M>
where
    M: Middleware,
{
    contract: PhantomSwapContract<M>,
    from_block: U64,
    last_block_seen: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct EncryptedOrderEvent {
    pub order_hash: H256,
    pub owner: H160,
    pub token_in: H160,
    pub token_out: H160,
    pub deadline: u64,
}

impl PhantomSwapWatcher<Provider<Http>> {
    pub fn new(provider: Provider<Http>, config: &RelayerConfig) -> Result<Self> {
        let contract = PhantomSwapContract::new(config.phantom_swap_address, Arc::new(provider));
        Ok(Self {
            contract,
            from_block: U64::from(0u64),
            last_block_seen: None,
        })
    }

    pub async fn fetch_new_orders(&mut self) -> Result<Vec<EncryptedOrderEvent>> {
        let client = self.contract.client();
        let filter = Filter::new()
            .address(self.contract.address())
            .event("OrderSubmitted(bytes32,address,address,address,uint64)")
            .from_block(self.from_block);

        let logs: Vec<Log> = client.get_logs(&filter).await?;
        if let Some(last) = logs.last() {
            if let Some(block) = last.block_number {
                self.from_block = block + 1;
                self.last_block_seen = Some(block.as_u64());
            }
        }

        let mut events = Vec::with_capacity(logs.len());
        for log in logs {
            let raw = RawLog {
                topics: log.topics.clone(),
                data: log.data.0.to_vec(),
            };
            let parsed = OrderSubmittedFilter::decode_log(&raw)?;
            events.push(EncryptedOrderEvent {
                order_hash: ethers::types::TxHash::from(parsed.order_hash),
                owner: parsed.owner,
                token_in: parsed.token_in,
                token_out: parsed.token_out,
                deadline: parsed.deadline,
            });
        }

        Ok(events)
    }

    pub fn set_from_block(&mut self, block: u64) {
        self.from_block = U64::from(block);
    }

    pub fn last_seen_block(&self) -> Option<u64> {
        self.last_block_seen
    }
}
