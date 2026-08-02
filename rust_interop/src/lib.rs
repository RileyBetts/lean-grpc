//! Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
//! Shared helpers for the Rust `grpc.testing` interop peer.

pub mod pb {
    tonic::include_proto!("grpc.testing");
}

pub mod echo;

use pb::Payload;

pub const LARGE_REQ: usize = 271_828;
pub const LARGE_RESP: i32 = 314_159;

pub fn zeros(n: usize) -> Vec<u8> {
    vec![0u8; n]
}

pub fn payload(n: usize) -> Payload {
    Payload {
        r#type: 0, // COMPRESSABLE
        body: zeros(n),
    }
}
