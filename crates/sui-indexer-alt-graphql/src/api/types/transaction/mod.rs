// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::ops::Deref;
use std::sync::Arc;

use anyhow::Context as _;
use async_graphql::Context;
use async_graphql::Object;
use async_graphql::connection::Connection;
use async_graphql::connection::CursorType;
use async_graphql::connection::Edge;
use async_graphql::dataloader::DataLoader;
use diesel::QueryableByName;
use diesel::sql_types::BigInt;
use fastcrypto::encoding::Base58;
use fastcrypto::encoding::Encoding;
use futures::future::try_join_all;
use prost_types::FieldMask;
use serde::Deserialize;
use serde::Serialize;
use sui_indexer_alt_reader::kv_loader::KvLoader;
use sui_indexer_alt_reader::kv_loader::TransactionContents as NativeTransactionContents;
use sui_indexer_alt_reader::ledger_grpc_reader::LedgerGrpcReader;
use sui_indexer_alt_reader::ledger_grpc_reader::TxStreamPage;
use sui_indexer_alt_reader::pg_reader::PgReader;
use sui_indexer_alt_reader::tx_digests::TxDigestKey;
use sui_pg_db::query::Query;
use sui_rpc::field::FieldMaskUtil;
use sui_rpc::proto::sui::rpc::v2alpha;
use sui_sql_macro::query;
use sui_types::base_types::SuiAddress as NativeSuiAddress;
use sui_types::digests::TransactionDigest;
use sui_types::transaction::TransactionDataAPI;
use sui_types::transaction::TransactionExpiration;

use crate::api::scalars::base64::Base64;
use crate::api::scalars::cursor::BcsCursor;
use crate::api::scalars::digest::Digest;
use crate::api::scalars::fq_name_filter::FqNameFilter;
use crate::api::scalars::id::Id;
use crate::api::scalars::json::Json;
use crate::api::scalars::sui_address::SuiAddress;
use crate::api::types::address::Address;
use crate::api::types::available_range::AvailableRangeKey;
use crate::api::types::checkpoint::filter::checkpoint_bounds;
use crate::api::types::epoch::Epoch;
use crate::api::types::gas_input::GasInput;
use crate::api::types::lookups::CheckpointBounds;
use crate::api::types::lookups::TxBoundsCursor;
use crate::api::types::transaction::filter::TransactionFilter;
use crate::api::types::transaction::filter::TransactionKindInput;
use crate::api::types::transaction_effects::EffectsContents;
use crate::api::types::transaction_effects::TransactionEffects;
use crate::api::types::transaction_kind::TransactionKind;
use crate::api::types::user_signature::UserSignature;
use crate::error::RpcError;
use crate::extensions::query_limits;
use crate::pagination::Page;
use crate::scope::Scope;
use crate::task::streaming::ProcessedTransaction;
use crate::task::watermark::Watermarks;

pub(crate) mod filter;

#[derive(Clone)]
pub(crate) struct Transaction {
    pub(crate) digest: TransactionDigest,
    pub(crate) contents: TransactionContents,
}

#[derive(Clone)]
pub(crate) struct TransactionContents {
    pub(crate) scope: Scope,
    pub(crate) contents: Option<Arc<NativeTransactionContents>>,
}

/// Cursor for transaction pagination, BCS-encoded. BCS serializes the enum's
/// variant index, which doubles as the discriminant that distinguishes the two
/// paths: the Postgres path emits/consumes `Seq` (a `tx_sequence_number`); the
/// bitmap path emits/consumes `Opaque` (the v2alpha `Watermark.cursor` bytes). A
/// cursor of the wrong variant for the active path is rejected loudly rather than
/// misinterpreted (see `Transaction::paginate`).
///
/// Note: this is a new wire format, so cursors minted by an older build won't
/// decode — acceptable, as pagination cursors are short-lived.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub(crate) enum TxCursor {
    Seq(u64),
    Opaque(Vec<u8>),
}

pub(crate) type CTransaction = BcsCursor<TxCursor>;

impl TxCursor {
    /// The `tx_sequence_number` for a Postgres-path cursor, or `None` for an
    /// opaque bitmap cursor.
    fn seq(&self) -> Option<u64> {
        match self {
            TxCursor::Seq(s) => Some(*s),
            TxCursor::Opaque(_) => None,
        }
    }
}

/// Description of a transaction, the unit of activity on Sui.
#[Object]
impl Transaction {
    /// The transaction's globally unique identifier, which can be passed to `Query.node` to refetch it.
    pub(crate) async fn id(&self) -> Id {
        Id::Transaction(self.digest)
    }

    /// A 32-byte hash that uniquely identifies the transaction contents, encoded in Base58.
    async fn digest(&self) -> String {
        Base58::encode(self.digest)
    }

    /// The results to the chain of executing this transaction.
    async fn effects(&self) -> Option<TransactionEffects> {
        Some(TransactionEffects::from(self.clone()))
    }

    /// The type of this transaction as well as the commands and/or parameters comprising the transaction of this kind.
    async fn kind(&self, ctx: &Context<'_>) -> Option<Result<TransactionKind, RpcError>> {
        async {
            let contents = self.contents.fetch(ctx, self.digest).await?;
            let Some(content) = &contents.contents else {
                return Ok(None);
            };

            let transaction_data = content.data()?;
            Ok(TransactionKind::from(
                transaction_data.kind().clone(),
                contents.scope.clone(),
            ))
        }
        .await
        .transpose()
    }

    #[graphql(flatten)]
    async fn contents(&self, ctx: &Context<'_>) -> Result<TransactionContents, RpcError> {
        self.contents.fetch(ctx, self.digest).await
    }
}

#[Object]
impl TransactionContents {
    /// This field is set by senders of a transaction block. It is an epoch reference that sets a deadline after which validators will no longer consider the transaction valid. By default, there is no deadline for when a transaction must execute.
    async fn expiration(&self) -> Option<Result<Epoch, RpcError>> {
        async {
            let Some(content) = &self.contents else {
                return Ok(None);
            };

            let transaction_data = content.data()?;
            match transaction_data.expiration() {
                TransactionExpiration::None => Ok(None),
                TransactionExpiration::Epoch(epoch_id) => {
                    Ok(Some(Epoch::with_id(self.scope.clone(), *epoch_id)))
                }
                TransactionExpiration::ValidDuring { max_epoch, .. } => {
                    if let Some(epoch_id) = max_epoch {
                        Ok(Some(Epoch::with_id(self.scope.clone(), *epoch_id)))
                    } else {
                        Ok(None)
                    }
                }
            }
        }
        .await
        .transpose()
    }

    /// The gas input field provides information on what objects were used as gas as well as the owner of the gas object(s) and information on the gas price and budget.
    async fn gas_input(&self) -> Option<Result<GasInput, RpcError>> {
        async {
            let Some(content) = &self.contents else {
                return Ok(None);
            };

            let transaction_data = content.data()?;
            Ok(Some(GasInput::from_gas_data(
                self.scope.clone(),
                transaction_data.gas_data().clone(),
            )))
        }
        .await
        .transpose()
    }

    /// The address corresponding to the public key that signed this transaction. System transactions do not have senders.
    async fn sender(&self) -> Option<Result<Address, RpcError>> {
        async {
            let Some(content) = &self.contents else {
                return Ok(None);
            };

            let sender = content.data()?.sender();
            Ok((sender != NativeSuiAddress::ZERO)
                .then(|| Address::with_address(self.scope.clone(), sender)))
        }
        .await
        .transpose()
    }

    /// The Base64-encoded BCS serialization of this transaction, as a `TransactionData`.
    async fn transaction_bcs(&self) -> Option<Result<Base64, RpcError>> {
        async {
            let Some(content) = &self.contents else {
                return Ok(None);
            };

            Ok(Some(Base64(content.raw_transaction()?)))
        }
        .await
        .transpose()
    }

    /// The transaction as a JSON blob, matching the gRPC proto format (excluding BCS).
    async fn transaction_json(&self) -> Option<Result<Json, RpcError>> {
        async {
            let Some(content) = &self.contents else {
                return Ok(None);
            };

            let mut proto_transaction = content.proto_transaction()?;
            // Clear the bcs field as transactionJson is intended to provide a full structured output
            proto_transaction.bcs = None;
            let json_value = serde_json::to_value(&proto_transaction)
                .context("Failed to serialize transaction to JSON")?;
            Ok(Some(json_value.try_into()?))
        }
        .await
        .transpose()
    }

    /// User signatures for this transaction.
    async fn signatures(&self) -> Result<Vec<UserSignature>, RpcError> {
        let Some(content) = &self.contents else {
            return Ok(vec![]);
        };

        let signatures = content.signatures()?;
        Ok(signatures
            .into_iter()
            .map(UserSignature::from_generic_signature)
            .collect())
    }
}

impl Transaction {
    /// Construct a transaction that is represented by just its identifier (its transaction
    /// digest). This does not check whether the transaction exists, so should not be used to
    /// "fetch" a transaction based on a digest provided as user input.
    pub(crate) fn with_digest(scope: Scope, digest: TransactionDigest) -> Self {
        Self {
            digest,
            contents: TransactionContents::empty(scope.with_active_transaction_digest(digest)),
        }
    }

    /// Construct a fully-inflated transaction with already-hydrated contents. The digest is
    /// read from `contents`, which keeps it consistent with the contents anchored on the scope.
    pub(crate) fn with_contents(
        scope: Scope,
        contents: Arc<NativeTransactionContents>,
    ) -> Result<Self, RpcError> {
        let digest = contents.digest()?;
        Ok(Self {
            digest,
            contents: TransactionContents {
                scope: scope.with_active_transaction_contents(digest, contents.clone()),
                contents: Some(contents),
            },
        })
    }

    /// Paginate over pre-loaded transactions, applying in-memory filtering.
    ///
    /// Used when transaction data is already available (e.g. from streaming) and doesn't
    /// require database queries. Cursors encode `tx_sequence_number` for consistency with
    /// the query API, enabling clients to continue paginating via queries.
    ///
    // TODO(DVX-2068): Add cursor consistency test between subscriptions and query API.
    pub(crate) fn paginate_preloaded_transactions(
        scope: Scope,
        transactions: &[ProcessedTransaction],
        page: &Page<CTransaction>,
        filter: TransactionFilter,
    ) -> Result<Connection<String, Transaction>, RpcError> {
        // Preloaded (streaming) pagination always uses sequence-number cursors; an
        // opaque cursor would yield `None` here, i.e. no bound.
        let after = page.after().and_then(|c| c.seq());
        let before = page.before().and_then(|c| c.seq());

        let filtered: Vec<_> = transactions
            .iter()
            .filter(|tx| filter.matches(&tx.contents))
            .filter(|tx| after.is_none_or(|a| tx.tx_sequence_number >= a))
            .filter(|tx| before.is_none_or(|b| tx.tx_sequence_number <= b))
            .take(page.limit_with_overhead())
            .collect();

        page.paginate_results(
            filtered,
            |tx| BcsCursor::new(TxCursor::Seq(tx.tx_sequence_number)),
            |tx| Transaction::with_contents(scope.clone(), tx.contents.clone()),
        )
    }

    /// Load the transaction from the store, and return it fully inflated (with contents already
    /// fetched). Returns `None` if the transaction does not exist (either never existed or was
    /// pruned from the store).
    pub(crate) async fn fetch(
        ctx: &Context<'_>,
        scope: Scope,
        digest: Digest,
    ) -> Result<Option<Self>, RpcError> {
        let fetched = TransactionContents::empty(scope.clone())
            .fetch(ctx, digest.into())
            .await?;

        let Some(contents) = fetched.contents else {
            return Ok(None);
        };

        Ok(Some(Self::with_contents(scope, contents)?))
    }

    /// Cursor based pagination through transactions with filters applied.
    ///
    /// Returns empty results when no checkpoint is set in scope (e.g. execution scope).
    pub(crate) async fn paginate(
        ctx: &Context<'_>,
        scope: Scope,
        page: Page<CTransaction>,
        filter: TransactionFilter,
    ) -> Result<Connection<String, Transaction>, RpcError> {
        // Serve non-`kind` transaction pagination from the roaring-bitmap index when a ledger gRPC
        // reader is present in the context. `kind` has no bitmap dimension and stays on Postgres.
        if filter.kind.is_none() {
            if let Some(reader) = ctx.data_opt::<LedgerGrpcReader>() {
                return Self::paginate_bitmap(ctx, reader, scope, page, filter).await;
            }
        }

        // Reject cursors incompatible with Postgres
        require_seq_cursor(page.after())?;
        require_seq_cursor(page.before())?;

        let watermarks: &Arc<Watermarks> = ctx.data()?;
        let available_range_key = AvailableRangeKey {
            type_: "Query".to_string(),
            field: Some("transactions".to_string()),
            filters: Some(filter.active_filters()),
        };
        let reader_lo = available_range_key.reader_lo(watermarks)?;

        let Some(query) = filter.tx_bounds(ctx, &scope, reader_lo, &page).await? else {
            return Ok(Connection::new(false, false));
        };

        let TransactionFilter {
            after_checkpoint: _,
            at_checkpoint: _,
            before_checkpoint: _,
            function,
            kind,
            affected_address,
            affected_object,
            sent_address,
        } = filter;

        let tx_sequence_numbers = if let Some(function) = function {
            tx_call(ctx, query, &page, function, sent_address).await?
        } else if let Some(kind) = kind {
            tx_kind(ctx, query, &page, kind, sent_address).await?
        } else if let Some(affected_object) = affected_object {
            tx_affected_object(ctx, query, &page, affected_object, sent_address).await?
        } else if let Some(address) = affected_address {
            tx_affected_address(ctx, query, &page, address, sent_address).await?
        } else if let Some(address) = sent_address {
            tx_affected_address(ctx, query, &page, address, sent_address).await?
        } else {
            tx_unfiltered(ctx, query, &page).await?
        };

        page.paginate_results(
            tx_digests(ctx, &tx_sequence_numbers).await?,
            |(s, _)| BcsCursor::new(TxCursor::Seq(*s)),
            |(_, d)| Ok(Self::with_digest(scope.clone(), d)),
        )
    }

    /// Serve transaction pagination from the roaring-bitmap index via the v2alpha
    /// `ListTransactions` stream. The checkpoint window is derived exactly as the
    /// Postgres path derives it (`checkpoint_bounds` over `reader_lo` /
    /// `checkpoint_viewed_at` / filter bounds) and sent as a checkpoint range; the
    /// opaque page cursors become `QueryOptions.after`/`before` (the position
    /// within that window). Hydration is digest-only — contents resolve lazily via
    /// `KvLoader` on field access, so this path never touches Postgres.
    async fn paginate_bitmap(
        ctx: &Context<'_>,
        reader: &LedgerGrpcReader,
        scope: Scope,
        page: Page<CTransaction>,
        filter: TransactionFilter,
    ) -> Result<Connection<String, Transaction>, RpcError> {
        if page.limit() == 0 {
            return Ok(Connection::new(false, false));
        }

        // Consistency upper bound; empty when scope has no checkpoint set.
        let Some(checkpoint_viewed_at) = scope.checkpoint_viewed_at() else {
            return Ok(Connection::new(false, false));
        };

        // Availability lower bound, keyed on the same active filters as the PG path.
        let watermarks: &Arc<Watermarks> = ctx.data()?;
        let available_range_key = AvailableRangeKey {
            type_: "Query".to_string(),
            field: Some("transactions".to_string()),
            filters: Some(filter.active_filters()),
        };
        let reader_lo = available_range_key.reader_lo(watermarks)?;

        let Some(cp_bounds) = checkpoint_bounds(
            filter.after_checkpoint().map(u64::from),
            filter.at_checkpoint().map(u64::from),
            filter.before_checkpoint().map(u64::from),
            reader_lo,
            checkpoint_viewed_at,
        ) else {
            return Ok(Connection::new(false, false));
        };

        // Opaque ledger-position bounds (ordering-independent); reject a stale
        // sequence-number cursor that reached the bitmap path.
        let after = bitmap_cursor(page.after())?;
        let before = bitmap_cursor(page.before())?;

        let mut options = v2alpha::QueryOptions::default();
        options.limit_items = Some((page.limit() + 1) as u32);
        options.after = after.map(|cursor| cursor.into());
        options.before = before.map(|cursor| cursor.into());
        options.ordering = if page.is_from_front() {
            v2alpha::Ordering::Ascending as i32
        } else {
            v2alpha::Ordering::Descending as i32
        };

        let mut request = v2alpha::ListTransactionsRequest::default();
        // Digest only — contents hydrate lazily via `KvLoader` on field access.
        request.read_mask = Some(FieldMask::from_paths(["digest"]));
        request.start_checkpoint = Some(*cp_bounds.start());
        // `cp_bounds` end is inclusive; the request bound is exclusive.
        request.end_checkpoint = Some(*cp_bounds.end() + 1);
        request.filter = filter.to_bitmap_filter();
        request.options = Some(options);

        // Chain grpc calls, accumulating items across drains until we either fill the page or the
        // server reports the range is exhausted (`next_cursor() == None`).
        //
        // Empirical evidence (Design Note §j.18) shows pathological intersections (`sender=0x0 +
        // move_call`) complete within budget for realistic data, so the loop reliably terminates
        // via `CheckpointBound` for the cases that matter. No PG fallback — bitmap errors surface
        // as graphql errors. The `kind` filter stays on Postgres (no bitmap dimension) via the
        // gate in `Transaction::paginate`.
        let target = page.limit() + 1;
        let mut accumulated_items = Vec::new();

        let (last_end_cursor, last_end_reason) = loop {
            let result = reader
                .list_transactions(request.clone())
                .await
                .map_err(|status| anyhow::anyhow!("ListTransactions request failed: {status}"))?;

            // Compute the resume cursor before destructuring — `next_cursor()`
            // borrows `result`, which the destructure then consumes.
            let next_cursor = result.next_cursor().cloned();
            let TxStreamPage {
                items,
                end_cursor,
                end_reason,
            } = result;
            accumulated_items.extend(items);

            if accumulated_items.len() >= target {
                break (end_cursor, end_reason);
            }

            // Single termination signal: `next_cursor()` returns the resume
            // point if the server has more buckets to walk, `None` if the
            // range is exhausted. Reader's invariant guarantees a non-`None`
            // value is always a valid resume cursor (protocol violations
            // surface as `data_loss` errors before reaching here).
            let Some(cursor) = next_cursor else {
                break (end_cursor, end_reason);
            };

            let options = request.options.as_mut().expect("options set above");
            let bound = Some(cursor.into());
            if page.is_from_front() {
                options.after = bound;
            } else {
                options.before = bound;
            }
        };

        // Synthesize a `TxStreamPage` from the accumulated state — `next_cursor()`
        // comes from the last drain's `end_reason` + `end_cursor` (whether the
        // *range* is exhausted), independent of how many items we collected
        // across drains. `build_bitmap_connection`'s over-fetch detection on
        // item count handles "page filled" trimming and `hasNextPage` semantics.
        let result = TxStreamPage {
            items: accumulated_items,
            end_cursor: last_end_cursor,
            end_reason: last_end_reason,
        };

        // Can't reuse `page.paginate_results`: it detects `hasPrev`/`hasNext`
        // via cursor equality with the supplied `after`/`before`, but v2alpha
        // bounds are exclusive (boundary never returned) and cursors are opaque
        // per-item watermarks, so the equality never fires. It also can't see
        // early stream termination (`SCAN_LIMIT`, `ITEM_LIMIT`, unknown end
        // reason, or no `QueryEnd` frame at all) as a "more results" signal.
        build_bitmap_connection(scope, &page, result)
    }
}

impl TransactionContents {
    fn empty(scope: Scope) -> Self {
        Self {
            scope,
            contents: None,
        }
    }

    /// Attempt to fill the contents. If the contents are already filled, returns a clone,
    /// otherwise attempts to fetch from the store. The resulting value may still have an empty
    /// contents field, because it could not be found in the store.
    pub(crate) async fn fetch(
        &self,
        ctx: &Context<'_>,
        digest: TransactionDigest,
    ) -> Result<Self, RpcError> {
        if self.contents.is_some() {
            return Ok(self.clone());
        }

        // Reuse contents anchored on the scope by a parent resolver (streaming and indexed
        // alike both anchor with hydrated contents when they have them).
        if let Some(contents) = self.scope.active_transaction_contents_for(digest) {
            return Ok(Self {
                scope: self.scope.clone(),
                contents: Some(contents.clone()),
            });
        }

        let Some(checkpoint_viewed_at) = self.scope.checkpoint_viewed_at() else {
            return Ok(self.clone());
        };

        let kv_loader: &KvLoader = ctx.data()?;
        let Some(transaction) = kv_loader
            .load_one_transaction(digest)
            .await
            .context("Failed to fetch transaction contents")?
        else {
            return Ok(self.clone());
        };

        // Discard the loaded result if we are viewing it at a checkpoint before it existed.
        let cp_num = transaction
            .cp_sequence_number()
            .context("Any transaction fetched from the DB should have a checkpoint set")?;
        if cp_num > checkpoint_viewed_at {
            return Ok(self.clone());
        }

        Ok(Self {
            scope: self.scope.clone(),
            contents: Some(Arc::new(transaction)),
        })
    }
}

impl TxBoundsCursor for CTransaction {
    fn tx_sequence_number(&self) -> u64 {
        match self.deref() {
            TxCursor::Seq(s) => *s,
            // Opaque (bitmap) cursors are rejected before the Postgres path runs
            // (`require_seq_cursor`); fall back to an empty range defensively.
            TxCursor::Opaque(_) => u64::MAX,
        }
    }
}

impl From<TransactionEffects> for Transaction {
    fn from(fx: TransactionEffects) -> Self {
        let EffectsContents { scope, contents } = fx.contents;

        Self {
            digest: fx.digest,
            contents: TransactionContents { scope, contents },
        }
    }
}

/// Build a relay `Connection` from a drained bitmap-scan page. The scan
/// over-fetches by one (`page.limit() + 1` requested) to detect a further
/// page strictly: if we got the over-fetched item, more definitely exist
/// (truncate to `page.limit()` and set `hasNextPage: true`). Otherwise
/// `result.next_cursor()` being `Some` is the orthogonal "server stopped
/// before exhausting the range" signal — true on non-exhausted terminations
/// (`ItemLimit` / `ScanLimit` / unknown end reason / stream cut short).
/// Edges are returned in ascending order, reversing a descending (`last`)
/// scan.
fn build_bitmap_connection(
    scope: Scope,
    page: &Page<CTransaction>,
    result: TxStreamPage,
) -> Result<Connection<String, Transaction>, RpcError> {
    let has_more = result.next_cursor().is_some();
    let TxStreamPage { mut items, .. } = result;

    let over_fetched = items.len() > page.limit();
    if over_fetched {
        items.truncate(page.limit());
    }
    let more = over_fetched || has_more;

    let (has_previous_page, has_next_page) = if page.is_from_front() {
        (page.after().is_some(), more)
    } else {
        // A descending (`last`) scan walks high -> low, so "more" means earlier
        // items remain before the page.
        (more, page.before().is_some())
    };

    if !page.is_from_front() {
        items.reverse();
    }

    let mut conn = Connection::new(has_previous_page, has_next_page);
    for item in items {
        let digest = item
            .transaction
            .as_ref()
            .and_then(|tx| tx.digest.as_deref())
            .context("ListTransactions item missing transaction digest")?
            .parse::<TransactionDigest>()
            .context("Failed to parse transaction digest from ListTransactions")?;

        let cursor = item
            .watermark
            .as_ref()
            .and_then(|w| w.cursor.as_ref())
            .context("ListTransactions item missing watermark cursor")?;
        let cursor = BcsCursor::new(TxCursor::Opaque(cursor.to_vec())).encode_cursor();

        conn.edges.push(Edge::new(
            cursor,
            Transaction::with_digest(scope.clone(), digest),
        ));
    }

    Ok(conn)
}

/// The opaque ledger-position bound for a bitmap scan, or `None` for no bound.
/// Errors on a sequence-number cursor (a stale Postgres cursor reaching the
/// bitmap path, e.g. after the flag was flipped mid-pagination) rather than
/// misinterpreting it.
fn bitmap_cursor(cursor: Option<&CTransaction>) -> Result<Option<Vec<u8>>, RpcError> {
    match cursor.map(|c| c.deref()) {
        None => Ok(None),
        Some(TxCursor::Opaque(bytes)) => Ok(Some(bytes.clone())),
        Some(TxCursor::Seq(_)) => Err(crate::pagination::Error::InvalidCursor.into()),
    }
}

/// Require a cursor that maps to a sequence, rejects otherwise.
fn require_seq_cursor(cursor: Option<&CTransaction>) -> Result<(), RpcError> {
    if matches!(cursor.map(|c| c.deref()), Some(TxCursor::Opaque(_))) {
        return Err(crate::pagination::Error::InvalidCursor.into());
    }
    Ok(())
}

pub(crate) async fn tx_digests(
    ctx: &Context<'_>,
    tx_sequence_numbers: &[u64],
) -> Result<Vec<(u64, TransactionDigest)>, RpcError> {
    let pg_loader: &Arc<DataLoader<PgReader>> = ctx.data()?;

    try_join_all(tx_sequence_numbers.iter().map(|&tx| async move {
        let stored = pg_loader
            .load_one(TxDigestKey(tx))
            .await
            .context("Failed to load transaction digest")?
            .context("Failed to find transaction digest")?;

        let digest = TransactionDigest::try_from(stored.tx_digest)
            .context("Failed to deserialize transaction digest")?;

        Ok((tx, digest))
    }))
    .await
}

async fn tx_affected_address(
    ctx: &Context<'_>,
    mut query: Query<'_>,
    page: &Page<CTransaction>,
    affected_address: SuiAddress,
    sent_address: Option<SuiAddress>,
) -> Result<Vec<u64>, RpcError> {
    query += query!(
        r#"
        SELECT
            tx_sequence_number
        FROM
            tx_affected_addresses
        WHERE
            affected = {Bytea}
        "#,
        affected_address.into_vec(),
    );

    if let Some(address) = sent_address {
        query += query!(" AND sender = {Bytea}", address.into_vec());
    }

    tx_sequence_numbers(ctx, query, page).await
}

async fn tx_affected_object(
    ctx: &Context<'_>,
    mut query: Query<'_>,
    page: &Page<CTransaction>,
    affected_object: SuiAddress,
    sent_address: Option<SuiAddress>,
) -> Result<Vec<u64>, RpcError> {
    query += query!(
        r#"
        SELECT
            tx_sequence_number
        FROM
            tx_affected_objects
        WHERE
            affected = {Bytea}
        "#,
        affected_object.into_vec(),
    );

    if let Some(address) = sent_address {
        query += query!(" AND sender = {Bytea}", address.into_vec());
    }

    tx_sequence_numbers(ctx, query, page).await
}

async fn tx_call(
    ctx: &Context<'_>,
    mut query: Query<'_>,
    page: &Page<CTransaction>,
    function: FqNameFilter,
    sent_address: Option<SuiAddress>,
) -> Result<Vec<u64>, RpcError> {
    query += query!(
        r#"
        SELECT
            tx_sequence_number
        FROM
            tx_calls
        WHERE
            package = {Bytea}
        "#,
        function.package().into_vec(),
    );

    if let Some(module) = function.module() {
        query += query!(" AND module = {Text}", module.to_string());
    }

    if let Some(name) = function.name() {
        query += query!(" AND function = {Text}", name.to_string());
    }

    if let Some(address) = sent_address {
        query += query!(" AND sender = {Bytea}", address.into_vec());
    }

    tx_sequence_numbers(ctx, query, page).await
}

async fn tx_kind(
    ctx: &Context<'_>,
    mut query: Query<'_>,
    page: &Page<CTransaction>,
    kind: TransactionKindInput,
    sent_address: Option<SuiAddress>,
) -> Result<Vec<u64>, RpcError> {
    match (kind, sent_address) {
        // We can simplify the query to just the `tx_affected_addresses` table if ProgrammableTX
        // and sender are specified.
        (TransactionKindInput::ProgrammableTx, Some(address)) => {
            tx_affected_address(ctx, query, page, address, Some(address)).await
        }

        (TransactionKindInput::SystemTx, Some(_)) => Ok(vec![]),

        // Otherwise, we can ignore the sender always, and just query the `tx_kinds` table.
        (_, None) => {
            query += query!(
                r#"
                SELECT
                    tx_sequence_number
                FROM
                    tx_kinds
                WHERE
                    tx_kind = {BigInt}
                "#,
                kind as i64,
            );

            tx_sequence_numbers(ctx, query, page).await
        }
    }
}

async fn tx_sequence_numbers(
    ctx: &Context<'_>,
    mut query: Query<'_>,
    page: &Page<CTransaction>,
) -> Result<Vec<u64>, RpcError> {
    query_limits::rich::debit(ctx)?;
    let pg_reader: &PgReader = ctx.data()?;

    query += query!(
        r#"
            AND (SELECT tx_lo FROM tx_lo) <= tx_sequence_number
            AND tx_sequence_number < (SELECT tx_hi FROM tx_hi)
        ORDER BY
            tx_sequence_number {} /* order_by_direction */
        LIMIT
            {BigInt} /* limit_with_overhead */
        "#,
        page.order_by_direction(),
        page.limit_with_overhead() as i64,
    );

    #[derive(QueryableByName)]
    struct TxSequenceNumber {
        #[diesel(sql_type = BigInt)]
        tx_sequence_number: i64,
    }

    let mut conn = pg_reader
        .connect()
        .await
        .context("Failed to connect to database")?;

    let wrapped_tx_sequence_numbers: Vec<TxSequenceNumber> = conn
        .results(query)
        .await
        .context("Failed to execute query")?;

    let tx_sequence_numbers = if page.is_from_front() {
        wrapped_tx_sequence_numbers
            .iter()
            .map(|t| t.tx_sequence_number as u64)
            .collect()
    } else {
        wrapped_tx_sequence_numbers
            .iter()
            .rev()
            .map(|t| t.tx_sequence_number as u64)
            .collect()
    };

    Ok(tx_sequence_numbers)
}

/// The tx_sequence_numbers with cursors applied inclusively.
/// Results are limited to `page.limit() + 2` to allow has_previous_page and has_next_page calculations.
async fn tx_unfiltered(
    ctx: &Context<'_>,
    mut query: Query<'_>,
    page: &Page<CTransaction>,
) -> Result<Vec<u64>, RpcError> {
    query_limits::rich::debit(ctx)?;
    let pg_reader: &PgReader = ctx.data()?;

    query += query!(
        r#"
        SELECT
            (SELECT tx_lo FROM tx_lo),
            (SELECT tx_hi FROM tx_hi)
        "#
    );

    #[derive(QueryableByName)]
    struct TxBounds {
        #[diesel(sql_type = BigInt)]
        tx_hi: i64,

        #[diesel(sql_type = BigInt)]
        tx_lo: i64,
    }

    let mut conn = pg_reader
        .connect()
        .await
        .context("Failed to connect to database")?;

    let results: Vec<TxBounds> = conn
        .results(query)
        .await
        .context("Failed to execute query")?;

    let (mut tx_lo, mut tx_hi) = results
        .first()
        .context("No valid checkpoints found")
        .map(|bounds| (bounds.tx_lo as u64, bounds.tx_hi as u64))?;

    let limit = page.limit_with_overhead() as u64;
    if page.is_from_front() {
        tx_hi = tx_hi.min(tx_lo.saturating_add(limit));
    } else {
        tx_lo = tx_lo.max(tx_hi.saturating_sub(limit));
    }

    let tx_sequence_numbers = (tx_lo..tx_hi).collect();
    Ok(tx_sequence_numbers)
}
