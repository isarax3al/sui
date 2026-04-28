// Copyright (c) The Move Contributors
// SPDX-License-Identifier: Apache-2.0

use std::io::{Cursor, Read};
use std::sync::Arc;

use crate::{
    VARIANT_TAG_MAX_VALUE,
    account_address::AccountAddress,
    compressed::{
        LayoutRef, LeafType, ResolvedRef, VariantTag,
        runtime::{
            MoveEnumLayout, MoveFieldsLayout, MoveStructLayout, MoveTypeLayout, MoveTypeLayoutPool,
            MoveTypeNode, VariantLayout,
        },
    },
    u256::U256,
};

/// Visitors can be used for building values out of a serialized Move struct or value.
pub trait Visitor<'b> {
    type Value;

    /// Visitors can return any error as long as it can represent an error from the visitor itself.
    /// The easiest way to achieve this is to use `thiserror`:
    ///
    /// ```rust,no_doc
    /// #[derive(thiserror::Error)]
    /// enum Error {
    ///     #[error(transparent)]
    ///     Visitor(#[from] runtime_visitor::Error)
    ///
    ///     // Custom error variants ...
    /// }
    /// ```
    type Error: From<Error>;

    fn visit_u8(&mut self, driver: &ValueDriver<'b>, value: u8)
    -> Result<Self::Value, Self::Error>;
    fn visit_u16(
        &mut self,
        driver: &ValueDriver<'b>,
        value: u16,
    ) -> Result<Self::Value, Self::Error>;
    fn visit_u32(
        &mut self,
        driver: &ValueDriver<'b>,
        value: u32,
    ) -> Result<Self::Value, Self::Error>;
    fn visit_u64(
        &mut self,
        driver: &ValueDriver<'b>,
        value: u64,
    ) -> Result<Self::Value, Self::Error>;
    fn visit_u128(
        &mut self,
        driver: &ValueDriver<'b>,
        value: u128,
    ) -> Result<Self::Value, Self::Error>;
    fn visit_u256(
        &mut self,
        driver: &ValueDriver<'b>,
        value: U256,
    ) -> Result<Self::Value, Self::Error>;
    fn visit_bool(
        &mut self,
        driver: &ValueDriver<'b>,
        value: bool,
    ) -> Result<Self::Value, Self::Error>;
    fn visit_address(
        &mut self,
        driver: &ValueDriver<'b>,
        value: AccountAddress,
    ) -> Result<Self::Value, Self::Error>;
    fn visit_signer(
        &mut self,
        driver: &ValueDriver<'b>,
        value: AccountAddress,
    ) -> Result<Self::Value, Self::Error>;
    fn visit_vector(&mut self, driver: &mut VecDriver<'_, 'b>) -> Result<Self::Value, Self::Error>;
    fn visit_struct(
        &mut self,
        driver: &mut StructDriver<'_, 'b>,
    ) -> Result<Self::Value, Self::Error>;
    fn visit_variant(
        &mut self,
        driver: &mut VariantDriver<'_, 'b>,
    ) -> Result<Self::Value, Self::Error>;
}

pub trait Traversal<'b> {
    type Error: From<Error>;

    fn traverse_u8(&mut self, _: &ValueDriver<'b>, _: u8) -> Result<(), Self::Error> {
        Ok(())
    }
    fn traverse_u16(&mut self, _: &ValueDriver<'b>, _: u16) -> Result<(), Self::Error> {
        Ok(())
    }
    fn traverse_u32(&mut self, _: &ValueDriver<'b>, _: u32) -> Result<(), Self::Error> {
        Ok(())
    }
    fn traverse_u64(&mut self, _: &ValueDriver<'b>, _: u64) -> Result<(), Self::Error> {
        Ok(())
    }
    fn traverse_u128(&mut self, _: &ValueDriver<'b>, _: u128) -> Result<(), Self::Error> {
        Ok(())
    }
    fn traverse_u256(&mut self, _: &ValueDriver<'b>, _: U256) -> Result<(), Self::Error> {
        Ok(())
    }
    fn traverse_bool(&mut self, _: &ValueDriver<'b>, _: bool) -> Result<(), Self::Error> {
        Ok(())
    }
    fn traverse_address(
        &mut self,
        _: &ValueDriver<'b>,
        _: AccountAddress,
    ) -> Result<(), Self::Error> {
        Ok(())
    }
    fn traverse_signer(
        &mut self,
        _: &ValueDriver<'b>,
        _: AccountAddress,
    ) -> Result<(), Self::Error> {
        Ok(())
    }
    fn traverse_vector(&mut self, driver: &mut VecDriver<'_, 'b>) -> Result<(), Self::Error> {
        while driver.next_element(self)?.is_some() {}
        Ok(())
    }
    fn traverse_struct(&mut self, driver: &mut StructDriver<'_, 'b>) -> Result<(), Self::Error> {
        while driver.next_field(self)?.is_some() {}
        Ok(())
    }
    fn traverse_variant(&mut self, driver: &mut VariantDriver<'_, 'b>) -> Result<(), Self::Error> {
        while driver.next_field(self)?.is_some() {}
        Ok(())
    }
}

impl<'b, T: Traversal<'b> + ?Sized> Visitor<'b> for T {
    type Value = ();
    type Error = T::Error;

    fn visit_u8(&mut self, d: &ValueDriver<'b>, v: u8) -> Result<(), T::Error> {
        self.traverse_u8(d, v)
    }
    fn visit_u16(&mut self, d: &ValueDriver<'b>, v: u16) -> Result<(), T::Error> {
        self.traverse_u16(d, v)
    }
    fn visit_u32(&mut self, d: &ValueDriver<'b>, v: u32) -> Result<(), T::Error> {
        self.traverse_u32(d, v)
    }
    fn visit_u64(&mut self, d: &ValueDriver<'b>, v: u64) -> Result<(), T::Error> {
        self.traverse_u64(d, v)
    }
    fn visit_u128(&mut self, d: &ValueDriver<'b>, v: u128) -> Result<(), T::Error> {
        self.traverse_u128(d, v)
    }
    fn visit_u256(&mut self, d: &ValueDriver<'b>, v: U256) -> Result<(), T::Error> {
        self.traverse_u256(d, v)
    }
    fn visit_bool(&mut self, d: &ValueDriver<'b>, v: bool) -> Result<(), T::Error> {
        self.traverse_bool(d, v)
    }
    fn visit_address(&mut self, d: &ValueDriver<'b>, v: AccountAddress) -> Result<(), T::Error> {
        self.traverse_address(d, v)
    }
    fn visit_signer(&mut self, d: &ValueDriver<'b>, v: AccountAddress) -> Result<(), T::Error> {
        self.traverse_signer(d, v)
    }
    fn visit_vector(&mut self, d: &mut VecDriver<'_, 'b>) -> Result<(), T::Error> {
        self.traverse_vector(d)
    }
    fn visit_struct(&mut self, d: &mut StructDriver<'_, 'b>) -> Result<(), T::Error> {
        self.traverse_struct(d)
    }
    fn visit_variant(&mut self, d: &mut VariantDriver<'_, 'b>) -> Result<(), T::Error> {
        self.traverse_variant(d)
    }
}

/// Exposes information about the byte stream that the value being visited came from, namely the
/// bytes themselves, and the offset at which the value starts. Also exposes the layout of the
/// value being visited.
///
/// Owns the cursor and the pool `Arc` for the entire visit; child drivers borrow this by `&mut`.
pub struct ValueDriver<'b> {
    cursor: Cursor<&'b [u8]>,
    pool: Arc<MoveTypeLayoutPool>,
    layout: Option<LayoutRef>,
    start: usize,
}

/// Exposes information about a vector being visited (the element layout) to a visitor
/// implementation, and allows that visitor to progress the traversal (by visiting or skipping
/// elements).
pub struct VecDriver<'p, 'b> {
    inner: &'p mut ValueDriver<'b>,
    elem: LayoutRef,
    len: u64,
    off: u64,
    /// Byte offset at which this vector's value started — captured at driver construction since
    /// `inner.start` is overwritten as we recurse into child values.
    start: usize,
    /// Layout of this vector value; captured for the same reason as `start`.
    layout: LayoutRef,
}

/// How the [`StructDriver`] was entered: either pointing at a node in the pool by index (the hot
/// descent path), or carrying a top-level [`MoveStructLayout`] supplied directly by the caller
/// (used by [`MoveStruct::visit_deserialize`]).
enum StructSource {
    Indexed(usize),
    TopLevel(MoveStructLayout),
}

/// Exposes information about a struct being visited (its layout, details about the next field to be
/// visited) to a visitor implementation, and allows that visitor to progress the traversal (by
/// visiting or skipping fields).
pub struct StructDriver<'p, 'b> {
    inner: &'p mut ValueDriver<'b>,
    /// Cached pointer to the field slice. The slice lives inside `inner.pool` (an
    /// `Arc<[MoveTypeNode]>`) for `Indexed`, or inside `src`'s owned `MoveStructLayout` for
    /// `TopLevel`. In both cases the slice is immutable and stays alive for the lifetime of
    /// `&self`.
    fields_ptr: *const [LayoutRef],
    src: StructSource,
    off: u64,
    /// Byte offset at which this struct's value started; captured for the same reason as
    /// [`VecDriver::start`].
    start: usize,
    /// Layout of this struct value; captured for the same reason as `start`. `None` only for the
    /// top-level `MoveStruct::visit_deserialize` entry, which carries the layout in `src` instead.
    layout: Option<LayoutRef>,
}

/// Exposes information about a variant being visited (its layout, details about the next field to
/// be visited, and the variant's tag) to a visitor implementation, and allows that visitor
/// to progress the traversal (by visiting or skipping fields).
pub struct VariantDriver<'p, 'b> {
    inner: &'p mut ValueDriver<'b>,
    /// Cached pointer to the field slice of the resolved variant; sits inside `inner.pool`.
    fields_ptr: *const [LayoutRef],
    enum_idx: usize,
    tag: u16,
    off: u64,
    /// Byte offset at which this variant's value started; captured for the same reason as
    /// [`VecDriver::start`].
    start: usize,
    /// Layout of this variant value (the enum's `LayoutRef`).
    layout: LayoutRef,
}

#[derive(thiserror::Error, Debug, Copy, Clone)]
pub enum Error {
    #[error("unexpected end of input")]
    UnexpectedEof,

    #[error("unexpected byte: {0}")]
    UnexpectedByte(u8),

    #[error("trailing {0} byte(s) at the end of input")]
    TrailingBytes(usize),

    #[error("invalid variant tag: {0}")]
    UnexpectedVariantTag(usize),

    #[error("no layout available for value")]
    NoValueLayout,
}

/// The null traversal implements `Traversal` and `Visitor` but without doing anything (does not
/// return a value, and does not modify any state). This is useful for skipping over parts of the
/// value structure.
pub struct NullTraversal;

impl Traversal<'_> for NullTraversal {
    type Error = Error;
}

impl<'b> ValueDriver<'b> {
    pub(crate) fn new(
        cursor: Cursor<&'b [u8]>,
        pool: Arc<MoveTypeLayoutPool>,
        layout: Option<LayoutRef>,
    ) -> Self {
        let start = cursor.position() as usize;
        Self {
            cursor,
            pool,
            layout,
            start,
        }
    }

    /// The offset at which the value being visited starts in the byte stream.
    pub fn start(&self) -> usize {
        self.start
    }

    /// The current position in the byte stream.
    pub fn position(&self) -> usize {
        self.cursor.position() as usize
    }

    /// All the bytes in the byte stream (including the ones that have been read).
    pub fn bytes(&self) -> &'b [u8] {
        self.cursor.get_ref()
    }

    /// The bytes that haven't been consumed by the visitor yet.
    pub fn remaining_bytes(&self) -> &'b [u8] {
        &self.cursor.get_ref()[self.position()..]
    }

    /// Type layout for the value being visited. May produce an error if a layout was not supplied
    /// when the driver was created (which should only happen if the driver was created for
    /// visiting a struct specifically).
    pub fn layout(&self) -> Result<MoveTypeLayout, Error> {
        let root = self.layout.ok_or(Error::NoValueLayout)?;
        Ok(MoveTypeLayout {
            pool: self.pool.clone(),
            root,
        })
    }

    fn read_exact<const N: usize>(&mut self) -> Result<[u8; N], Error> {
        let mut buf = [0u8; N];
        self.cursor
            .read_exact(&mut buf)
            .map_err(|_| Error::UnexpectedEof)?;
        Ok(buf)
    }

    fn read_leb128(&mut self) -> Result<u64, Error> {
        leb128::read::unsigned(&mut self.cursor).map_err(|_| Error::UnexpectedEof)
    }
}

#[allow(clippy::len_without_is_empty)]
impl<'p, 'b> VecDriver<'p, 'b> {
    /// The offset at which the value being visited starts in the byte stream.
    pub fn start(&self) -> usize {
        self.start
    }

    /// The current position in the byte stream.
    pub fn position(&self) -> usize {
        self.inner.position()
    }

    /// All the bytes in the byte stream (including the ones that have been read).
    pub fn bytes(&self) -> &'b [u8] {
        self.inner.bytes()
    }

    /// The bytes that haven't been consumed by the visitor yet.
    pub fn remaining_bytes(&self) -> &'b [u8] {
        self.inner.remaining_bytes()
    }

    /// Type layout for the value being visited (the vector itself).
    pub fn layout(&self) -> Result<MoveTypeLayout, Error> {
        Ok(MoveTypeLayout {
            pool: self.inner.pool.clone(),
            root: self.layout,
        })
    }

    /// Type layout for the vector's element type. Materializes via one `Arc` clone.
    pub fn element_layout(&self) -> MoveTypeLayout {
        MoveTypeLayout {
            pool: self.inner.pool.clone(),
            root: self.elem,
        }
    }

    /// The number of elements in this vector that have been visited so far.
    pub fn off(&self) -> u64 {
        self.off
    }

    /// The number of elements in this vector.
    pub fn len(&self) -> u64 {
        self.len
    }

    /// Returns whether or not there are more elements to visit in this vector.
    pub fn has_element(&self) -> bool {
        self.off < self.len
    }

    /// Visit the next element in the vector. The driver accepts a visitor to use for this element,
    /// allowing the visitor to be changed on recursive calls or even between elements in the same
    /// vector.
    ///
    /// Returns `Ok(None)` if there are no more elements in the vector, `Ok(v)` if there was an
    /// element and it was successfully visited (where `v` is the value returned by the visitor) or
    /// an error if there was an underlying deserialization error, or an error during visitation.
    pub fn next_element<V: Visitor<'b> + ?Sized>(
        &mut self,
        visitor: &mut V,
    ) -> Result<Option<V::Value>, V::Error> {
        if self.off >= self.len {
            return Ok(None);
        }
        let res = visit_value(self.inner, self.elem, visitor)?;
        self.off += 1;
        Ok(Some(res))
    }

    /// Skip the next element in this vector. Returns whether there was an element to skip or not on
    /// success, or an error if there was an underlying deserialization error.
    pub fn skip_element(&mut self) -> Result<bool, Error> {
        self.next_element(&mut NullTraversal).map(|v| v.is_some())
    }
}

impl<'p, 'b> StructDriver<'p, 'b> {
    /// The offset at which the value being visited starts in the byte stream.
    pub fn start(&self) -> usize {
        self.start
    }

    /// The current position in the byte stream.
    pub fn position(&self) -> usize {
        self.inner.position()
    }

    /// All the bytes in the byte stream (including the ones that have been read).
    pub fn bytes(&self) -> &'b [u8] {
        self.inner.bytes()
    }

    /// The bytes that haven't been consumed by the visitor yet.
    pub fn remaining_bytes(&self) -> &'b [u8] {
        self.inner.remaining_bytes()
    }

    /// Type layout for the value being visited. May produce an error if a layout was not supplied
    /// when the driver was created (which should only happen if the driver was created for
    /// visiting a struct specifically).
    pub fn layout(&self) -> Result<MoveTypeLayout, Error> {
        let root = self.layout.ok_or(Error::NoValueLayout)?;
        Ok(MoveTypeLayout {
            pool: self.inner.pool.clone(),
            root,
        })
    }

    /// The number of fields in this struct that have been visited so far.
    pub fn off(&self) -> u64 {
        self.off
    }

    fn fields(&self) -> &[LayoutRef] {
        // SAFETY: `fields_ptr` was derived from a slice held by either the `Arc<Pool>` in `inner`
        // (Indexed) or the owned `MoveStructLayout` in `self.src` (TopLevel). Either way, the
        // backing storage is alive and immutable for the lifetime of `&self`.
        unsafe { &*self.fields_ptr }
    }

    /// The layout of the struct being visited. Materializes via one `Arc` clone.
    pub fn struct_layout(&self) -> MoveStructLayout {
        match &self.src {
            StructSource::Indexed(idx) => match &self.inner.pool[*idx] {
                MoveTypeNode::Struct(s) => MoveStructLayout(MoveFieldsLayout::from_parts(
                    self.inner.pool.clone(),
                    s.fields.clone(),
                )),
                _ => unreachable!("StructDriver::Indexed always points at a Struct node"),
            },
            StructSource::TopLevel(layout) => layout.clone(),
        }
    }

    /// The layout of the next field to be visited (if there is one), or `None` otherwise.
    /// Materializes via one `Arc` clone.
    pub fn peek_field(&self) -> Option<MoveTypeLayout> {
        let r = *self.fields().get(self.off as usize)?;
        Some(MoveTypeLayout {
            pool: self.inner.pool.clone(),
            root: r,
        })
    }

    /// Visit the next field in the struct. The driver accepts a visitor to use for this field,
    /// allowing the visitor to be changed on recursive calls or even between fields in the same
    /// struct.
    ///
    /// Returns `Ok(None)` if there are no more fields in the struct, `Ok(v)` if there was a field
    /// and it was successfully visited (where `v` is the value returned by the visitor) or an
    /// error if there was an underlying deserialization error, or an error during visitation.
    pub fn next_field<V: Visitor<'b> + ?Sized>(
        &mut self,
        visitor: &mut V,
    ) -> Result<Option<V::Value>, V::Error> {
        let layout_ref = match self.fields().get(self.off as usize) {
            Some(r) => *r,
            None => return Ok(None),
        };
        let res = visit_value(self.inner, layout_ref, visitor)?;
        self.off += 1;
        Ok(Some(res))
    }

    /// Skip the next field. Returns `true` if there was a field to skip, or `false` if there was
    /// none. Can return an error if there was a deserialization error.
    pub fn skip_field(&mut self) -> Result<bool, Error> {
        self.next_field(&mut NullTraversal).map(|v| v.is_some())
    }
}

impl<'p, 'b> VariantDriver<'p, 'b> {
    /// The offset at which the value being visited starts in the byte stream.
    pub fn start(&self) -> usize {
        self.start
    }

    /// The current position in the byte stream.
    pub fn position(&self) -> usize {
        self.inner.position()
    }

    /// All the bytes in the byte stream (including the ones that have been read).
    pub fn bytes(&self) -> &'b [u8] {
        self.inner.bytes()
    }

    /// The bytes that haven't been consumed by the visitor yet.
    pub fn remaining_bytes(&self) -> &'b [u8] {
        self.inner.remaining_bytes()
    }

    /// Type layout for the value being visited (the enum).
    pub fn layout(&self) -> Result<MoveTypeLayout, Error> {
        Ok(MoveTypeLayout {
            pool: self.inner.pool.clone(),
            root: self.layout,
        })
    }

    /// The number of fields in this variant that have been visited so far.
    pub fn off(&self) -> u64 {
        self.off
    }

    /// The tag of the variant being visited.
    pub fn tag(&self) -> u16 {
        self.tag
    }

    fn fields(&self) -> &[LayoutRef] {
        // SAFETY: `fields_ptr` was derived from a slice held by the `Arc<Pool>` in `inner` (the
        // variant's `Arc<[LayoutRef]>`), alive for the lifetime of `&self`.
        unsafe { &*self.fields_ptr }
    }

    /// The layout of the enum being visited. Materializes via one `Arc` clone.
    pub fn enum_layout(&self) -> MoveEnumLayout {
        match &self.inner.pool[self.enum_idx] {
            MoveTypeNode::Enum(e) => {
                let pool = self.inner.pool.clone();
                let variants: Arc<[VariantLayout]> = e
                    .variants
                    .iter()
                    .map(|v| match v {
                        Some(fs) => VariantLayout::Known(MoveFieldsLayout::from_parts(
                            pool.clone(),
                            fs.clone(),
                        )),
                        None => VariantLayout::Unknown,
                    })
                    .collect();
                MoveEnumLayout::from_parts(variants)
            }
            _ => unreachable!("VariantDriver always points at an Enum node"),
        }
    }

    /// The layout of the variant being visited (its field list). Materializes via one `Arc` clone.
    pub fn variant_layout(&self) -> MoveFieldsLayout {
        let MoveTypeNode::Enum(e) = &self.inner.pool[self.enum_idx] else {
            unreachable!("VariantDriver always points at an Enum node");
        };
        let fields = e.variants[self.tag as usize]
            .clone()
            .expect("VariantDriver only constructed for known-fields variants");
        MoveFieldsLayout::from_parts(self.inner.pool.clone(), fields)
    }

    /// The layout of the next field to be visited (if there is one), or `None` otherwise.
    /// Materializes via one `Arc` clone.
    pub fn peek_field(&self) -> Option<MoveTypeLayout> {
        let r = *self.fields().get(self.off as usize)?;
        Some(MoveTypeLayout {
            pool: self.inner.pool.clone(),
            root: r,
        })
    }

    /// Visit the next field in the variant. The driver accepts a visitor to use for this field,
    /// allowing the visitor to be changed on recursive calls or even between fields in the same
    /// variant.
    ///
    /// Returns `Ok(None)` if there are no more fields in the variant, `Ok(v)` if there was a
    /// field and it was successfully visited (where `v` is the value returned by the visitor) or
    /// an error if there was an underlying deserialization error, or an error during visitation.
    pub fn next_field<V: Visitor<'b> + ?Sized>(
        &mut self,
        visitor: &mut V,
    ) -> Result<Option<V::Value>, V::Error> {
        let layout_ref = match self.fields().get(self.off as usize) {
            Some(r) => *r,
            None => return Ok(None),
        };
        let res = visit_value(self.inner, layout_ref, visitor)?;
        self.off += 1;
        Ok(Some(res))
    }

    /// Skip the next field. Returns `true` if there was a field to skip, or `false` if there was
    /// none. Can return an error if there was a deserialization error.
    pub fn skip_field(&mut self) -> Result<bool, Error> {
        self.next_field(&mut NullTraversal).map(|v| v.is_some())
    }
}

/// Visit a serialized Move value at `layout_ref`, reusing the parent driver's cursor and pool.
/// See `runtime_value::MoveValue::visit_deserialize` for details on top-level entry.
pub(crate) fn visit_value<'b, V: Visitor<'b> + ?Sized>(
    driver: &mut ValueDriver<'b>,
    layout_ref: LayoutRef,
    visitor: &mut V,
) -> Result<V::Value, V::Error> {
    driver.layout = Some(layout_ref);
    driver.start = driver.cursor.position() as usize;

    match layout_ref.resolve() {
        ResolvedRef::Leaf(LeafType::Bool) => match driver.read_exact()? {
            [0] => visitor.visit_bool(driver, false),
            [1] => visitor.visit_bool(driver, true),
            [b] => Err(Error::UnexpectedByte(b).into()),
        },
        ResolvedRef::Leaf(LeafType::U8) => {
            let v = u8::from_le_bytes(driver.read_exact()?);
            visitor.visit_u8(driver, v)
        }
        ResolvedRef::Leaf(LeafType::U16) => {
            let v = u16::from_le_bytes(driver.read_exact()?);
            visitor.visit_u16(driver, v)
        }
        ResolvedRef::Leaf(LeafType::U32) => {
            let v = u32::from_le_bytes(driver.read_exact()?);
            visitor.visit_u32(driver, v)
        }
        ResolvedRef::Leaf(LeafType::U64) => {
            let v = u64::from_le_bytes(driver.read_exact()?);
            visitor.visit_u64(driver, v)
        }
        ResolvedRef::Leaf(LeafType::U128) => {
            let v = u128::from_le_bytes(driver.read_exact()?);
            visitor.visit_u128(driver, v)
        }
        ResolvedRef::Leaf(LeafType::U256) => {
            let v = U256::from_le_bytes(&driver.read_exact()?);
            visitor.visit_u256(driver, v)
        }
        ResolvedRef::Leaf(LeafType::Address) => {
            let v = AccountAddress::new(driver.read_exact()?);
            visitor.visit_address(driver, v)
        }
        ResolvedRef::Leaf(LeafType::Signer) => {
            let v = AccountAddress::new(driver.read_exact()?);
            visitor.visit_signer(driver, v)
        }
        ResolvedRef::Index(idx) => {
            let kind = match &driver.pool[idx] {
                MoveTypeNode::Vector(elem) => CompoundKind::Vector(*elem),
                MoveTypeNode::Struct(_) => CompoundKind::Struct,
                MoveTypeNode::Enum(_) => CompoundKind::Enum,
            };
            match kind {
                CompoundKind::Vector(elem) => visit_vector(driver, layout_ref, elem, visitor),
                CompoundKind::Struct => visit_struct_indexed(driver, layout_ref, idx, visitor),
                CompoundKind::Enum => visit_variant(driver, layout_ref, idx, visitor),
            }
        }
    }
}

enum CompoundKind {
    Vector(LayoutRef),
    Struct,
    Enum,
}

/// Like `visit_value` but specialized to visiting a vector (where the bytes are known to be a
/// serialized Move vector), with `elem` as the vector's element layout.
fn visit_vector<'b, V: Visitor<'b> + ?Sized>(
    driver: &mut ValueDriver<'b>,
    layout: LayoutRef,
    elem: LayoutRef,
    visitor: &mut V,
) -> Result<V::Value, V::Error> {
    let start = driver.start;
    let len = driver.read_leb128()?;
    let mut vd = VecDriver {
        inner: driver,
        elem,
        len,
        off: 0,
        start,
        layout,
    };
    let res = visitor.visit_vector(&mut vd)?;
    while vd.skip_element()? {}
    Ok(res)
}

/// Like `visit_value` but specialized to visiting a struct found in the pool at `struct_idx`.
fn visit_struct_indexed<'b, V: Visitor<'b> + ?Sized>(
    driver: &mut ValueDriver<'b>,
    layout: LayoutRef,
    struct_idx: usize,
    visitor: &mut V,
) -> Result<V::Value, V::Error> {
    let start = driver.start;
    let fields_ptr: *const [LayoutRef] = match &driver.pool[struct_idx] {
        MoveTypeNode::Struct(s) => &*s.fields,
        _ => unreachable!("visit_struct_indexed called with non-struct node"),
    };
    let mut sd = StructDriver {
        inner: driver,
        fields_ptr,
        src: StructSource::Indexed(struct_idx),
        off: 0,
        start,
        layout: Some(layout),
    };
    let res = visitor.visit_struct(&mut sd)?;
    while sd.skip_field()? {}
    Ok(res)
}

/// Like `visit_value` but specialized to visiting a struct (where the bytes are known to be a
/// serialized Move struct), with `layout` an owned [`MoveStructLayout`] supplied by the caller.
/// Used by [`crate::runtime_value::MoveStruct::visit_deserialize`].
pub(crate) fn visit_struct<'b, V: Visitor<'b> + ?Sized>(
    driver: &mut ValueDriver<'b>,
    layout: MoveStructLayout,
    visitor: &mut V,
) -> Result<V::Value, V::Error> {
    let start = driver.start;
    let fields_ptr: *const [LayoutRef] = &*layout.0.fields;
    let mut sd = StructDriver {
        inner: driver,
        fields_ptr,
        src: StructSource::TopLevel(layout),
        off: 0,
        start,
        layout: None,
    };
    let res = visitor.visit_struct(&mut sd)?;
    while sd.skip_field()? {}
    Ok(res)
}

/// Like `visit_struct` but specialized to visiting a variant of the enum found in the pool at
/// `enum_idx`.
fn visit_variant<'b, V: Visitor<'b> + ?Sized>(
    driver: &mut ValueDriver<'b>,
    layout: LayoutRef,
    enum_idx: usize,
    visitor: &mut V,
) -> Result<V::Value, V::Error> {
    let driver_start = driver.start;
    let [tag_byte] = driver.read_exact()?;
    if tag_byte > VARIANT_TAG_MAX_VALUE as u8 {
        return Err(Error::UnexpectedVariantTag(tag_byte as usize).into());
    }
    let tag = tag_byte as VariantTag;
    let fields_ptr: *const [LayoutRef] = {
        let MoveTypeNode::Enum(e) = &driver.pool[enum_idx] else {
            unreachable!("visit_variant called with non-enum node");
        };
        let variant = e
            .variants
            .get(tag as usize)
            .ok_or(Error::UnexpectedVariantTag(tag as usize))?;
        match variant {
            Some(fs) => &**fs,
            None => return Err(Error::NoValueLayout.into()),
        }
    };
    let mut vd = VariantDriver {
        inner: driver,
        fields_ptr,
        enum_idx,
        tag,
        off: 0,
        start: driver_start,
        layout,
    };
    let res = visitor.visit_variant(&mut vd)?;
    while vd.skip_field()? {}
    Ok(res)
}
