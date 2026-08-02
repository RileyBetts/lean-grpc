//! Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
//! Minimal Rust gRPC interop server for Lean client → Rust tests (tonic).

use std::net::SocketAddr;
use std::pin::Pin;
use std::time::Duration;

use async_stream::try_stream;
use clap::Parser;
use futures::Stream;
use tokio_stream::StreamExt;
use tonic::codec::CompressionEncoding;
use tonic::transport::Server;
use tonic::{Code, Request, Response, Status, Streaming};

use rust_interop::echo::EchoHeadersSvc;
use rust_interop::pb::test_service_server::{TestService, TestServiceServer};
use rust_interop::pb::unimplemented_service_server::{
    UnimplementedService, UnimplementedServiceServer,
};
use rust_interop::pb::*;
use rust_interop::zeros;

#[derive(Parser, Debug)]
#[command(about = "Rust interop server for lean-grpc")]
struct Args {
    #[arg(long, default_value_t = 10001)]
    port: u16,
}

type BoxStream<T> = Pin<Box<dyn Stream<Item = Result<T, Status>> + Send + 'static>>;

#[derive(Default)]
struct TestSvc;

#[tonic::async_trait]
impl TestService for TestSvc {
    async fn empty_call(&self, _request: Request<Empty>) -> Result<Response<Empty>, Status> {
        Ok(Response::new(Empty {}))
    }

    async fn unary_call(
        &self,
        request: Request<SimpleRequest>,
    ) -> Result<Response<SimpleResponse>, Status> {
        let req = request.into_inner();
        if let Some(echo_status) = req.response_status {
            return Err(Status::new(
                Code::from_i32(echo_status.code),
                echo_status.message,
            ));
        }
        if req.response_size < 0 {
            return Err(Status::invalid_argument("response_size cannot be negative"));
        }
        let mut username = String::new();
        let mut oauth_scope = String::new();
        // Auth fill fields are best-effort for Lean credential cases.
        if req.fill_username {
            username = "rust".into();
        }
        if req.fill_oauth_scope {
            oauth_scope = "https://www.googleapis.com/auth/xapi.zoo".into();
        }
        Ok(Response::new(SimpleResponse {
            payload: Some(Payload {
                r#type: 0,
                body: zeros(req.response_size as usize),
            }),
            username,
            oauth_scope,
            ..Default::default()
        }))
    }

    async fn cacheable_unary_call(
        &self,
        request: Request<SimpleRequest>,
    ) -> Result<Response<SimpleResponse>, Status> {
        self.unary_call(request).await
    }

    type StreamingOutputCallStream = BoxStream<StreamingOutputCallResponse>;

    async fn streaming_output_call(
        &self,
        request: Request<StreamingOutputCallRequest>,
    ) -> Result<Response<Self::StreamingOutputCallStream>, Status> {
        let StreamingOutputCallRequest {
            response_parameters,
            ..
        } = request.into_inner();

        let stream = try_stream! {
            for param in response_parameters {
                if param.interval_us > 0 {
                    tokio::time::sleep(Duration::from_micros(param.interval_us as u64)).await;
                }
                yield StreamingOutputCallResponse {
                    payload: Some(Payload {
                        r#type: 0,
                        body: zeros(param.size as usize),
                    }),
                    ..Default::default()
                };
            }
        };
        Ok(Response::new(
            Box::pin(stream) as Self::StreamingOutputCallStream
        ))
    }

    async fn streaming_input_call(
        &self,
        request: Request<Streaming<StreamingInputCallRequest>>,
    ) -> Result<Response<StreamingInputCallResponse>, Status> {
        let mut stream = request.into_inner();
        let mut aggregated_payload_size = 0i32;
        while let Some(msg) = stream.try_next().await? {
            if let Some(payload) = msg.payload {
                aggregated_payload_size += payload.body.len() as i32;
            }
        }
        Ok(Response::new(StreamingInputCallResponse {
            aggregated_payload_size,
        }))
    }

    type FullDuplexCallStream = BoxStream<StreamingOutputCallResponse>;

    async fn full_duplex_call(
        &self,
        request: Request<Streaming<StreamingOutputCallRequest>>,
    ) -> Result<Response<Self::FullDuplexCallStream>, Status> {
        let mut inbound = request.into_inner();
        let stream = try_stream! {
            while let Some(msg) = inbound.message().await? {
                if let Some(echo_status) = msg.response_status {
                    if echo_status.message == "sleep" {
                        // Longer than typical interop client deadlines (e.g. 1ms / 100ms).
                        tokio::time::sleep(Duration::from_secs(2)).await;
                    } else {
                        Err(Status::new(
                            Code::from_i32(echo_status.code),
                            echo_status.message,
                        ))?;
                    }
                }
                for param in msg.response_parameters {
                    if param.interval_us > 0 {
                        tokio::time::sleep(Duration::from_micros(param.interval_us as u64)).await;
                    }
                    yield StreamingOutputCallResponse {
                        payload: Some(Payload {
                            r#type: 0,
                            body: zeros(param.size as usize),
                        }),
                        ..Default::default()
                    };
                }
            }
        };
        Ok(Response::new(
            Box::pin(stream) as Self::FullDuplexCallStream
        ))
    }

    type HalfDuplexCallStream = BoxStream<StreamingOutputCallResponse>;

    async fn half_duplex_call(
        &self,
        request: Request<Streaming<StreamingOutputCallRequest>>,
    ) -> Result<Response<Self::HalfDuplexCallStream>, Status> {
        let mut inbound = request.into_inner();
        let mut buffered = Vec::new();
        while let Some(msg) = inbound.message().await? {
            buffered.push(msg);
        }
        let stream = try_stream! {
            for msg in buffered {
                if let Some(echo_status) = msg.response_status {
                    Err(Status::new(
                        Code::from_i32(echo_status.code),
                        echo_status.message,
                    ))?;
                }
                for param in msg.response_parameters {
                    yield StreamingOutputCallResponse {
                        payload: Some(Payload {
                            r#type: 0,
                            body: zeros(param.size as usize),
                        }),
                        ..Default::default()
                    };
                }
            }
        };
        Ok(Response::new(
            Box::pin(stream) as Self::HalfDuplexCallStream
        ))
    }

    async fn unimplemented_call(&self, _request: Request<Empty>) -> Result<Response<Empty>, Status> {
        Err(Status::unimplemented("unimplemented"))
    }
}

#[derive(Default)]
struct UnimplementedSvc;

#[tonic::async_trait]
impl UnimplementedService for UnimplementedSvc {
    async fn unimplemented_call(&self, _request: Request<Empty>) -> Result<Response<Empty>, Status> {
        Err(Status::unimplemented("unimplemented"))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    let addr: SocketAddr = format!("127.0.0.1:{}", args.port).parse()?;

    let test = TestServiceServer::new(TestSvc::default())
        .accept_compressed(CompressionEncoding::Gzip)
        .send_compressed(CompressionEncoding::Gzip);
    let unimpl = UnimplementedServiceServer::new(UnimplementedSvc::default());

    println!("rust interop server on {addr}");
    Server::builder()
        .add_service(EchoHeadersSvc::new(test))
        .add_service(EchoHeadersSvc::new(unimpl))
        .serve(addr)
        .await?;
    Ok(())
}
