//! Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
//! Rust gRPC interop client (same non-auth cases as the Python/Go stock clients).

use std::time::Duration;

use clap::Parser;
use futures::StreamExt;
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tonic::codec::CompressionEncoding;
use tonic::metadata::MetadataValue;
use tonic::transport::Channel;
use tonic::{Code, Request};

use rust_interop::pb::test_service_client::TestServiceClient;
use rust_interop::pb::unimplemented_service_client::UnimplementedServiceClient;
use rust_interop::pb::*;
use rust_interop::{payload, LARGE_REQ, LARGE_RESP};

#[derive(Parser, Debug)]
#[command(about = "Rust interop client for lean-grpc")]
struct Args {
    /// Same flag spelling as python_interop/client.py / stock Go client.
    #[arg(long = "server_host", default_value = "127.0.0.1")]
    server_host: String,
    #[arg(long = "server_port", default_value_t = 10000)]
    server_port: u16,
    #[arg(long = "test_case")]
    test_case: String,
    #[arg(long = "use_tls", default_value_t = false)]
    use_tls: bool,
}

type Client = TestServiceClient<Channel>;

async fn connect(
    host: &str,
    port: u16,
) -> Result<(Client, Channel), Box<dyn std::error::Error>> {
    let dest = format!("http://{host}:{port}");
    let channel = Channel::from_shared(dest)?.connect().await?;
    // Match Python: default identity; accept gzip so server_compressed_* can negotiate.
    // Do NOT send_compressed globally — Lean peers only expect gzip on compress cases.
    let client = TestServiceClient::new(channel.clone())
        .accept_compressed(CompressionEncoding::Gzip);
    Ok((client, channel))
}

fn with_gzip_send(client: &Client) -> Client {
    client
        .clone()
        .send_compressed(CompressionEncoding::Gzip)
        .accept_compressed(CompressionEncoding::Gzip)
}

async fn run_case(
    client: &mut Client,
    channel: &Channel,
    case: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    match case {
        "empty_unary" => {
            client.empty_call(Request::new(Empty {})).await?;
        }
        "large_unary" => {
            let resp = client
                .unary_call(Request::new(SimpleRequest {
                    response_size: LARGE_RESP,
                    payload: Some(payload(LARGE_REQ)),
                    ..Default::default()
                }))
                .await?
                .into_inner();
            let n = resp.payload.as_ref().map(|p| p.body.len()).unwrap_or(0);
            if n != LARGE_RESP as usize {
                return Err(format!("large_unary size {n} != {LARGE_RESP}").into());
            }
        }
        "status_code_and_message" => {
            let err = client
                .unary_call(Request::new(SimpleRequest {
                    response_status: Some(EchoStatus {
                        code: 2,
                        message: "test status message".into(),
                    }),
                    ..Default::default()
                }))
                .await
                .expect_err("expected RPC error");
            if err.code() != Code::Unknown || err.message() != "test status message" {
                return Err(format!("bad status: {err:?}").into());
            }
        }
        "special_status_message" => {
            let msg = "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n";
            let err = client
                .unary_call(Request::new(SimpleRequest {
                    response_status: Some(EchoStatus {
                        code: 2,
                        message: msg.into(),
                    }),
                    ..Default::default()
                }))
                .await
                .expect_err("expected RPC error");
            if err.code() != Code::Unknown || err.message() != msg {
                return Err(format!("bad special status: {err:?}").into());
            }
        }
        "custom_metadata" => {
            let key1 = "x-grpc-test-echo-initial";
            let value1: MetadataValue<_> = "test_initial_metadata_value".parse()?;
            let key2 = "x-grpc-test-echo-trailing-bin";
            let value2 = MetadataValue::from_bytes(&[0x0a, 0x0b, 0x0a, 0x0b, 0x0a, 0x0b]);

            let mut req = Request::new(SimpleRequest {
                response_size: 1,
                payload: Some(payload(1)),
                ..Default::default()
            });
            req.metadata_mut().insert(key1, value1.clone());
            req.metadata_mut().insert_bin(key2, value2.clone());
            let resp = client.unary_call(req).await?;
            if resp.metadata().get(key1) != Some(&value1) {
                return Err("missing initial md on unary".into());
            }

            let (tx, rx) = mpsc::channel(1);
            tx.send(StreamingOutputCallRequest {
                response_parameters: vec![ResponseParameters {
                    size: 1,
                    ..Default::default()
                }],
                payload: Some(payload(1)),
                ..Default::default()
            })
            .await?;
            drop(tx);
            let mut stream_req = Request::new(ReceiverStream::new(rx));
            stream_req.metadata_mut().insert(key1, value1.clone());
            stream_req.metadata_mut().insert_bin(key2, value2.clone());
            let resp = client.full_duplex_call(stream_req).await?;
            if resp.metadata().get(key1) != Some(&value1) {
                return Err("missing initial md on duplex".into());
            }
            let mut stream = resp.into_inner();
            let _ = stream.message().await?;
            let trailers = stream
                .trailers()
                .await?
                .ok_or("missing trailers on duplex")?;
            if trailers.get_bin(key2) != Some(&value2) {
                return Err("missing trailing-bin on duplex".into());
            }
        }
        "cancel_after_begin" => {
            let (tx, rx) = mpsc::channel::<StreamingInputCallRequest>(1);
            // Keep the sender alive so the stream stays open until we cancel.
            let mut c = client.clone();
            let handle = tokio::spawn(async move {
                c.streaming_input_call(ReceiverStream::new(rx)).await
            });
            tokio::time::sleep(Duration::from_millis(50)).await;
            handle.abort();
            match handle.await {
                Err(e) if e.is_cancelled() => {}
                Ok(Err(_)) => {}
                Ok(Ok(_)) => return Err("expected cancelled call".into()),
                Err(e) => return Err(format!("join error: {e}").into()),
            }
            drop(tx);
        }
        "cancel_after_first_response" => {
            let (tx, rx) = mpsc::channel(4);
            tx.send(StreamingOutputCallRequest {
                response_parameters: vec![ResponseParameters {
                    size: 31415,
                    ..Default::default()
                }],
                ..Default::default()
            })
            .await?;
            let mut stream = client
                .full_duplex_call(ReceiverStream::new(rx))
                .await?
                .into_inner();
            let first = stream.message().await?;
            if first.is_none() {
                return Err("expected first response before cancel".into());
            }
            drop(tx);
            drop(stream);
        }
        "server_streaming" => {
            let sizes = [31415, 9, 2653, 58979];
            let resp = client
                .streaming_output_call(Request::new(StreamingOutputCallRequest {
                    response_parameters: sizes
                        .iter()
                        .map(|s| ResponseParameters {
                            size: *s,
                            ..Default::default()
                        })
                        .collect(),
                    ..Default::default()
                }))
                .await?
                .into_inner();
            let bodies: Vec<usize> = resp
                .filter_map(|r| async move { r.ok().and_then(|m| m.payload).map(|p| p.body.len()) })
                .collect()
                .await;
            if bodies != sizes.map(|s| s as usize).to_vec() {
                return Err(format!("server_streaming got {bodies:?}").into());
            }
        }
        "client_streaming" => {
            let sizes = [27182, 8, 1828, 45904];
            let requests = sizes.into_iter().map(|s| StreamingInputCallRequest {
                payload: Some(payload(s as usize)),
                ..Default::default()
            });
            let resp = client
                .streaming_input_call(Request::new(tokio_stream::iter(requests)))
                .await?
                .into_inner();
            if resp.aggregated_payload_size != sizes.iter().sum::<i32>() {
                return Err(format!(
                    "client_streaming agg {}",
                    resp.aggregated_payload_size
                )
                .into());
            }
        }
        "ping_pong" => {
            let sizes = [31415, 9, 2653, 58979];
            let requests = sizes.into_iter().map(|s| StreamingOutputCallRequest {
                response_parameters: vec![ResponseParameters {
                    size: s,
                    ..Default::default()
                }],
                ..Default::default()
            });
            let stream = client
                .full_duplex_call(Request::new(tokio_stream::iter(requests)))
                .await?
                .into_inner();
            let got: Vec<usize> = stream
                .filter_map(|r| async move { r.ok().and_then(|m| m.payload).map(|p| p.body.len()) })
                .collect()
                .await;
            if got != sizes.map(|s| s as usize).to_vec() {
                return Err(format!("ping_pong got {got:?}").into());
            }
        }
        "empty_stream" => {
            let stream = client
                .full_duplex_call(Request::new(tokio_stream::empty::<
                    StreamingOutputCallRequest,
                >()))
                .await?
                .into_inner();
            let n = stream.collect::<Vec<_>>().await.len();
            if n != 0 {
                return Err(format!("empty_stream got {n} msgs").into());
            }
        }
        "timeout_on_sleeping_server" => {
            let mut req = Request::new(tokio_stream::once(StreamingOutputCallRequest {
                response_status: Some(EchoStatus {
                    code: 0,
                    message: "sleep".into(),
                }),
                ..Default::default()
            }));
            req.set_timeout(Duration::from_millis(100));
            let result = client.full_duplex_call(req).await;
            match result {
                Err(e) if e.code() == Code::DeadlineExceeded => {}
                Ok(resp) => {
                    let drain = resp.into_inner().collect::<Vec<_>>().await;
                    if drain.iter().all(|r| r.is_ok()) {
                        return Err("expected deadline exceeded".into());
                    }
                }
                Err(e) => {
                    // Some peers surface cancel/unknown on short deadlines.
                    if e.code() == Code::Ok {
                        return Err(format!("unexpected ok-ish error {e:?}").into());
                    }
                }
            }
        }
        "unimplemented_method" => {
            let err = client
                .unimplemented_call(Request::new(Empty {}))
                .await
                .expect_err("expected unimplemented");
            if err.code() != Code::Unimplemented {
                return Err(format!("expected UNIMPLEMENTED got {:?}", err.code()).into());
            }
        }
        "unimplemented_service" => {
            let mut bad = UnimplementedServiceClient::new(channel.clone());
            let err = bad
                .unimplemented_call(Request::new(Empty {}))
                .await
                .expect_err("expected unimplemented");
            if err.code() != Code::Unimplemented {
                return Err(format!("expected UNIMPLEMENTED got {:?}", err.code()).into());
            }
        }
        "client_compressed_unary" => {
            let mut gzip_client = with_gzip_send(client);
            let resp = gzip_client
                .unary_call(Request::new(SimpleRequest {
                    response_size: 31415,
                    payload: Some(payload(27182)),
                    expect_compressed: Some(BoolValue { value: true }),
                    ..Default::default()
                }))
                .await?
                .into_inner();
            let n = resp.payload.as_ref().map(|p| p.body.len()).unwrap_or(0);
            if n != 31415 {
                return Err(format!("client_compressed_unary size {n}").into());
            }
        }
        "server_compressed_unary" => {
            // Request stays identity; accept_compressed (set on connect) lets Lean gzip the reply.
            let resp = client
                .unary_call(Request::new(SimpleRequest {
                    response_size: 31415,
                    payload: Some(payload(27182)),
                    response_compressed: Some(BoolValue { value: true }),
                    ..Default::default()
                }))
                .await?
                .into_inner();
            let n = resp.payload.as_ref().map(|p| p.body.len()).unwrap_or(0);
            if n != 31415 {
                return Err(format!("server_compressed_unary size {n}").into());
            }
        }
        "server_compressed_streaming" => {
            // Same as unary: identity request, gzip-capable accept encoding only.
            let sizes = [31415, 92653];
            let req = StreamingOutputCallRequest {
                response_parameters: sizes
                    .iter()
                    .map(|n| ResponseParameters {
                        size: *n,
                        compressed: Some(BoolValue { value: true }),
                        ..Default::default()
                    })
                    .collect(),
                ..Default::default()
            };
            let bodies: Vec<usize> = client
                .streaming_output_call(Request::new(req))
                .await?
                .into_inner()
                .filter_map(|r| async move { r.ok().and_then(|m| m.payload).map(|p| p.body.len()) })
                .collect()
                .await;
            if bodies != sizes.map(|s| s as usize).to_vec() {
                return Err(format!("server_compressed_streaming {bodies:?}").into());
            }
        }
        other => return Err(format!("unknown/unsupported rust case: {other}").into()),
    }
    Ok(())
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    if args.use_tls {
        eprintln!("TLS not wired in this helper; use h2c");
        std::process::exit(2);
    }
    let result = async {
        let (mut client, channel) = connect(&args.server_host, args.server_port).await?;
        run_case(&mut client, &channel, &args.test_case).await?;
        println!("{} OK", args.test_case);
        Ok::<(), Box<dyn std::error::Error>>(())
    }
    .await;
    if let Err(e) = result {
        eprintln!("FAIL: {e}");
        std::process::exit(1);
    }
}
