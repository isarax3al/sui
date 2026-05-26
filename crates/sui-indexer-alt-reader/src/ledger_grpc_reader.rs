// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::time::Duration;

use anyhow::Context;
use async_graphql::dataloader::DataLoader;
use bytes::Bytes;
use prometheus::Registry;
use sui_rpc::proto::sui::rpc::v2 as grpc;
use sui_rpc::proto::sui::rpc::v2::ledger_service_client::LedgerServiceClient as V2LedgerServiceClient;
use sui_rpc::proto::sui::rpc::v2alpha as grpc_alpha;
use sui_rpc::proto::sui::rpc::v2alpha::ledger_service_client::LedgerServiceClient as V2alphaLedgerServiceClient;
use sui_types::effects::TransactionEffects;
use sui_types::event::Event;
use sui_types::messages_checkpoint::CheckpointSummary;
use sui_types::signature::GenericSignature;
use sui_types::transaction::TransactionData;
use tonic::transport::Channel;
use tonic::transport::ClientTlsConfig;
use tonic::transport::Uri;
use tower::Layer;
use tracing::warn;

use crate::metrics::GrpcMetricsLayer;
use crate::metrics::GrpcMetricsService;

const DEFAULT_MAX_DECODING_MESSAGE_SIZE: usize = 32 * 1024 * 1024;

#[derive(clap::Args, Debug, Clone, Default)]
pub struct LedgerGrpcArgs {
    /// Timeout for gRPC statements to the ledger service, in milliseconds.
    #[arg(long)]
    pub ledger_grpc_statement_timeout_ms: Option<u64>,

    /// Maximum gRPC decoding message size for Ledger service responses, in bytes.
    #[arg(long)]
    pub ledger_grpc_max_decoding_message_size: Option<usize>,
}

#[derive(Debug, Clone)]
pub struct CheckpointedTransaction {
    pub effects: Box<TransactionEffects>,
    pub events: Option<Vec<Event>>,
    pub transaction_data: Box<TransactionData>,
    pub signatures: Vec<GenericSignature>,
    pub timestamp_ms: Option<u64>,
    pub cp_sequence_number: Option<u64>,
    pub balance_changes: Vec<grpc::BalanceChange>,
}

/// A reader backed by gRPC LedgerService (sui-kv-rpc).
///
/// This connects to archival service that implements the same LedgerService gRPC interface
/// as fullnode, but is backed by Bigtable for serving historical data.
#[derive(Clone)]
pub struct LedgerGrpcReader {
    client: V2LedgerServiceClient<GrpcMetricsService<Channel>>,
    alpha_client: V2alphaLedgerServiceClient<GrpcMetricsService<Channel>>,
    timeout: Option<Duration>,
}

/// A drained page from a `ListTransactions` server stream consisting of the matched transaction
/// items in stream order, the latest watermark cursor to continue paginating on, and why the stream
/// stopped.
///
/// `end_cursor` may be beyond the last item in the collected page.
///
/// `end_reason` is `None` only when the stream terminated before a `QueryEnd` was received.
/// Partially collected results are valid and `end_cursor` is a valid resume point.
#[derive(Debug, Clone, Default)]
pub struct TxStreamPage {
    pub items: Vec<grpc_alpha::TransactionItem>,
    pub end_cursor: Option<Bytes>,
    pub end_reason: Option<grpc_alpha::QueryEndReason>,
}

impl LedgerGrpcArgs {
    pub fn statement_timeout(&self) -> Option<std::time::Duration> {
        self.ledger_grpc_statement_timeout_ms
            .map(Duration::from_millis)
    }
}

impl LedgerGrpcReader {
    pub async fn new(
        uri: Uri,
        args: LedgerGrpcArgs,
        prefix: Option<&str>,
        registry: &Registry,
    ) -> anyhow::Result<Self> {
        let mut endpoint = Channel::builder(uri.clone());
        if let Some(timeout) = args.statement_timeout() {
            endpoint = endpoint.timeout(timeout);
        }

        if uri.scheme_str() == Some("https") {
            let tls_config = ClientTlsConfig::new().with_native_roots();
            endpoint = endpoint.tls_config(tls_config)?;
        }

        let channel = endpoint.connect_lazy();
        let layered =
            GrpcMetricsLayer::new(prefix.unwrap_or("ledger_grpc"), registry).layer(channel);

        let timeout = args.statement_timeout();
        let max_decoding_message_size = args
            .ledger_grpc_max_decoding_message_size
            .unwrap_or(DEFAULT_MAX_DECODING_MESSAGE_SIZE);
        let client = V2LedgerServiceClient::new(layered.clone())
            .max_decoding_message_size(max_decoding_message_size);
        let alpha_client = V2alphaLedgerServiceClient::new(layered)
            .max_decoding_message_size(max_decoding_message_size);

        Ok(Self {
            client,
            alpha_client,
            timeout,
        })
    }

    pub fn as_data_loader(&self) -> DataLoader<Self> {
        DataLoader::new(self.clone(), tokio::spawn)
    }

    pub async fn checkpoint_watermark(&self) -> anyhow::Result<CheckpointSummary> {
        use grpc::GetCheckpointRequest;
        use prost_types::FieldMask;
        use sui_rpc::field::FieldMaskUtil;

        let request =
            GetCheckpointRequest::default().with_read_mask(FieldMask::from_paths(["summary.bcs"]));

        let response = self.get_checkpoint(request).await?;

        let checkpoint = response.checkpoint.context("No checkpoint returned")?;

        checkpoint
            .summary
            .as_ref()
            .and_then(|s| s.bcs.as_ref())
            .context("Missing summary.bcs")?
            .deserialize()
            .context("Failed to deserialize checkpoint summary")
    }

    /// Resolve a checkpoint digest to its sequence number via the ledger service. Returns `None`
    /// if no checkpoint with that digest is known.
    pub async fn checkpoint_seq_by_digest(
        &self,
        digest: sui_types::digests::CheckpointDigest,
    ) -> anyhow::Result<Option<u64>> {
        use grpc::GetCheckpointRequest;
        use prost_types::FieldMask;
        use sui_rpc::field::FieldMaskUtil;

        let sdk_digest = sui_sdk_types::Digest::new(digest.inner().to_owned());
        let request = GetCheckpointRequest::by_digest(&sdk_digest)
            .with_read_mask(FieldMask::from_paths(["sequence_number"]));

        match self.get_checkpoint(request).await {
            Ok(response) => {
                let checkpoint = response.checkpoint.context("No checkpoint returned")?;
                Ok(checkpoint.sequence_number)
            }
            Err(status) if status.code() == tonic::Code::NotFound => Ok(None),
            Err(e) => Err(anyhow::anyhow!(e)),
        }
    }

    // Public wrapper methods for gRPC calls with metrics instrumentation

    pub async fn get_checkpoint(
        &self,
        request: grpc::GetCheckpointRequest,
    ) -> Result<grpc::GetCheckpointResponse, tonic::Status> {
        self.client
            .clone()
            .get_checkpoint(self.request(request))
            .await
            .map(|r| r.into_inner())
    }

    pub async fn batch_get_transactions(
        &self,
        request: grpc::BatchGetTransactionsRequest,
    ) -> Result<grpc::BatchGetTransactionsResponse, tonic::Status> {
        self.client
            .clone()
            .batch_get_transactions(self.request(request))
            .await
            .map(|r| r.into_inner())
    }

    pub async fn batch_get_objects(
        &self,
        request: grpc::BatchGetObjectsRequest,
    ) -> Result<grpc::BatchGetObjectsResponse, tonic::Status> {
        self.client
            .clone()
            .batch_get_objects(self.request(request))
            .await
            .map(|r| r.into_inner())
    }

    pub async fn get_transaction(
        &self,
        request: grpc::GetTransactionRequest,
    ) -> Result<grpc::GetTransactionResponse, tonic::Status> {
        self.client
            .clone()
            .get_transaction(self.request(request))
            .await
            .map(|r| r.into_inner())
    }

    /// Open the `v2alpha` `ListTransactions` server stream for `request` and drain it into a single
    /// [`TxStreamPage`]. This consumes the stream until server timeout or a terminal condition is
    /// met. The caller is responsible for resuming the next page from the `end_cursor` if there are
    /// more results to yield after the current page.
    pub async fn list_transactions(
        &self,
        request: grpc_alpha::ListTransactionsRequest,
    ) -> Result<TxStreamPage, tonic::Status> {
        let mut stream = self
            .alpha_client
            .clone()
            .list_transactions(self.request(request))
            .await?
            .into_inner();

        let mut page = TxStreamPage::default();
        loop {
            match stream.message().await {
                Ok(Some(response)) => {
                    if let Some(frame) = response.response {
                        // `QueryEnd` is contractually the terminal frame: stop as
                        // soon as we see it rather than waiting on the server to
                        // half-close (a misbehaving server might never do so).
                        if page.apply(frame) {
                            break;
                        }
                    }
                }
                // We expect the server to yield an `End` frame before reaching this branch
                Ok(None) => break,
                Err(status) if status.code() == tonic::Code::DeadlineExceeded => {
                    // Propagate the error if zero progress was made so the user could reshape the
                    // query
                    if page.items.is_empty() && page.end_cursor.is_none() {
                        return Err(status);
                    }
                    // Otherwise surface the partial results
                    break;
                }
                Err(status) => return Err(status),
            }
        }

        // Invariant for callers: if the server reports more results remain
        // (`has_more()`), there must be a resume cursor — either from a
        // standalone `Watermark` frame or carried on the last `Item`'s
        // watermark. A non-exhausted terminal reason with no advanced cursor
        // is a server protocol violation: the page is unresumable and silently
        // returning it would lose forward progress for the caller. Surface as
        // a `data_loss` error so callers can fall back rather than spin or
        // misinterpret.
        if page.has_more() && page.end_cursor.is_none() {
            return Err(tonic::Status::data_loss(
                "server reported more results but did not advance cursor — cannot resume",
            ));
        }

        Ok(page)
    }

    /// Create a gRPC request, optionally with the grpc-timeout header if configured.
    fn request<T>(&self, input: T) -> tonic::Request<T> {
        let mut request = tonic::Request::new(input);
        if let Some(timeout) = self.timeout {
            request.set_timeout(timeout);
        }
        request
    }
}

impl TxStreamPage {
    /// True while the server has not exhausted the requested range.
    pub fn has_more(&self) -> bool {
        !matches!(
            self.end_reason,
            Some(
                grpc_alpha::QueryEndReason::CheckpointBound
                    | grpc_alpha::QueryEndReason::CursorBound
                    | grpc_alpha::QueryEndReason::LedgerTip
            )
        )
    }

    /// The cursor to continue paginating, or `None` if the requested range has been exhausted and
    /// no further pagination is possible.
    ///
    /// Invariant: `has_more()` ⇒ `end_cursor.is_some()`. Enforced at the page boundary by
    /// `list_transactions` (returns `data_loss` on violation) and preserved by any caller that
    /// re-synthesizes a `TxStreamPage` from a previously-validated one's `end_reason` +
    /// `end_cursor` fields together.
    pub fn next_cursor(&self) -> Option<&Bytes> {
        self.has_more().then(|| {
            self.end_cursor
                .as_ref()
                .expect("invariant: has_more implies end_cursor is Some")
        })
    }

    /// Fold one streamed response frame into the page. The resume cursor is the
    /// latest watermark cursor seen on either an item or a standalone watermark
    /// frame; the terminal `QueryEnd` frame carries only the stop reason.
    ///
    /// Returns `true` when `frame` is the terminal `QueryEnd`, signalling the
    /// caller to stop draining.
    fn apply(&mut self, frame: grpc_alpha::list_transactions_response::Response) -> bool {
        use grpc_alpha::list_transactions_response::Response;

        match frame {
            Response::Item(item) => {
                if let Some(cursor) = item.watermark.as_ref().and_then(|w| w.cursor.clone()) {
                    self.end_cursor = Some(cursor);
                }
                self.items.push(item);
                false
            }
            Response::Watermark(watermark) => {
                if let Some(cursor) = watermark.cursor {
                    self.end_cursor = Some(cursor);
                }
                false
            }
            Response::End(end) => {
                // Fold an unknown reason int into `Unspecified` so `None`
                // remains unambiguous shorthand for "no End frame received"
                // (i.e. the deadline cut the stream short). An unknown variant
                // means the server's proto has evolved past our pinned SDK —
                // log it so the skew is visible to ops. The page is still
                // resumable via `end_cursor`, so we don't fail the request.
                self.end_reason = match grpc_alpha::QueryEndReason::try_from(end.reason) {
                    Ok(reason) => Some(reason),
                    Err(_) => {
                        warn!(
                            reason_int = end.reason,
                            "ListTransactions: server sent QueryEndReason \
                             variant unknown to this build — SDK proto skew",
                        );
                        Some(grpc_alpha::QueryEndReason::Unspecified)
                    }
                };
                true
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item_frame(cursor: &[u8]) -> grpc_alpha::list_transactions_response::Response {
        let mut watermark = grpc_alpha::Watermark::default();
        watermark.cursor = Some(Bytes::copy_from_slice(cursor));
        let mut item = grpc_alpha::TransactionItem::default();
        item.watermark = Some(watermark);
        grpc_alpha::list_transactions_response::Response::Item(item)
    }

    fn watermark_frame(cursor: &[u8]) -> grpc_alpha::list_transactions_response::Response {
        let mut watermark = grpc_alpha::Watermark::default();
        watermark.cursor = Some(Bytes::copy_from_slice(cursor));
        grpc_alpha::list_transactions_response::Response::Watermark(watermark)
    }

    fn end_frame(
        reason: grpc_alpha::QueryEndReason,
    ) -> grpc_alpha::list_transactions_response::Response {
        let mut end = grpc_alpha::QueryEnd::default();
        end.reason = reason as i32;
        grpc_alpha::list_transactions_response::Response::End(end)
    }

    #[test]
    fn drains_items_tracking_latest_cursor_and_end_reason() {
        let mut page = TxStreamPage::default();
        assert!(!page.apply(item_frame(b"c1")));
        assert!(!page.apply(watermark_frame(b"c2")));
        assert!(!page.apply(item_frame(b"c3")));
        // The terminal `QueryEnd` frame signals the caller to stop draining.
        assert!(page.apply(end_frame(grpc_alpha::QueryEndReason::ItemLimit)));

        assert_eq!(page.items.len(), 2);
        // Latest cursor wins, including a standalone watermark between items.
        assert_eq!(page.end_cursor.as_deref(), Some(b"c3".as_ref()));
        assert_eq!(page.end_reason, Some(grpc_alpha::QueryEndReason::ItemLimit));
    }

    #[test]
    fn standalone_watermark_advances_cursor_without_items() {
        let mut page = TxStreamPage::default();
        assert!(!page.apply(watermark_frame(b"w1")));
        assert!(page.apply(end_frame(grpc_alpha::QueryEndReason::LedgerTip)));

        assert!(page.items.is_empty());
        assert_eq!(page.end_cursor.as_deref(), Some(b"w1".as_ref()));
        assert_eq!(page.end_reason, Some(grpc_alpha::QueryEndReason::LedgerTip));
    }

    #[test]
    fn has_more_true_when_truncated_or_timed_out() {
        // ITEM_LIMIT and SCAN_LIMIT both signal "we stopped short, resume here".
        for reason in [
            grpc_alpha::QueryEndReason::ItemLimit,
            grpc_alpha::QueryEndReason::ScanLimit,
        ] {
            let mut page = TxStreamPage::default();
            page.apply(end_frame(reason));
            assert!(page.has_more(), "expected has_more for {reason:?}");
        }

        // `end_reason == None` covers both the deadline cut-short case (no
        // terminal frame received) and any unrecognized / future-added variant
        // — defaulting to "may have more" avoids silent truncation.
        let page = TxStreamPage::default();
        assert!(page.has_more());
    }

    #[test]
    fn has_more_false_when_range_exhausted() {
        for reason in [
            grpc_alpha::QueryEndReason::CheckpointBound,
            grpc_alpha::QueryEndReason::CursorBound,
            grpc_alpha::QueryEndReason::LedgerTip,
        ] {
            let mut page = TxStreamPage::default();
            page.apply(end_frame(reason));
            assert!(!page.has_more(), "expected !has_more for {reason:?}");
        }
    }
}
