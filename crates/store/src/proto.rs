#![allow(
    non_camel_case_types,
    dead_code,
    unused_imports,
    clippy::derivable_impls,
    clippy::doc_lazy_continuation,
    clippy::match_single_binding,
    clippy::uninlined_format_args
)]

pub mod store {
    pub mod v1 {
        include!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../proto/generated/rust/buffa/proto.store.rs"
        ));
        include!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../proto/generated/rust/connect/proto.store.rs"
        ));
    }
}
