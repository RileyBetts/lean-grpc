//! Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
//! Tower middleware that echoes official interop metadata headers/trailers.
//!
//! Matches tonic's own interop `EchoHeadersSvc`: copy
//! `x-grpc-test-echo-initial` into response headers and
//! `x-grpc-test-echo-trailing-bin` into response trailers.

use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};

use http::header::{HeaderName, HeaderValue};
use http_body::Body;
use pin_project::pin_project;
use tonic::body::BoxBody;
use tonic::server::NamedService;
use tower::Service;

type BoxFuture<T, E> = Pin<Box<dyn Future<Output = Result<T, E>> + Send + 'static>>;

#[derive(Clone, Default)]
pub struct EchoHeadersSvc<S> {
    inner: S,
}

impl<S> EchoHeadersSvc<S> {
    pub fn new(inner: S) -> Self {
        Self { inner }
    }
}

impl<S: NamedService> NamedService for EchoHeadersSvc<S> {
    const NAME: &'static str = S::NAME;
}

impl<S> Service<http::Request<BoxBody>> for EchoHeadersSvc<S>
where
    S: Service<http::Request<BoxBody>, Response = http::Response<BoxBody>> + Send,
    S::Future: Send + 'static,
{
    type Response = S::Response;
    type Error = S::Error;
    type Future = BoxFuture<Self::Response, Self::Error>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, req: http::Request<BoxBody>) -> Self::Future {
        let echo_header = req.headers().get("x-grpc-test-echo-initial").cloned();
        let echo_trailer = req
            .headers()
            .get("x-grpc-test-echo-trailing-bin")
            .cloned()
            .map(|v| (HeaderName::from_static("x-grpc-test-echo-trailing-bin"), v));

        let call = self.inner.call(req);
        Box::pin(async move {
            let mut res = call.await?;
            if let Some(echo_header) = echo_header {
                res.headers_mut()
                    .insert("x-grpc-test-echo-initial", echo_header);
            }
            if echo_trailer.is_some() {
                Ok(res.map(|b| BoxBody::new(MergeTrailers::new(b, echo_trailer))))
            } else {
                Ok(res)
            }
        })
    }
}

#[pin_project]
pub struct MergeTrailers<B> {
    #[pin]
    inner: B,
    trailer: Option<(HeaderName, HeaderValue)>,
}

impl<B> MergeTrailers<B> {
    pub fn new(inner: B, trailer: Option<(HeaderName, HeaderValue)>) -> Self {
        Self { inner, trailer }
    }
}

impl<B> Body for MergeTrailers<B>
where
    B: Body,
{
    type Data = B::Data;
    type Error = B::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<http_body::Frame<Self::Data>, Self::Error>>> {
        let this = self.project();
        let mut frame = match this.inner.poll_frame(cx) {
            Poll::Pending => return Poll::Pending,
            Poll::Ready(None) => return Poll::Ready(None),
            Poll::Ready(Some(Err(e))) => return Poll::Ready(Some(Err(e))),
            Poll::Ready(Some(Ok(f))) => f,
        };
        if let Some(trailers) = frame.trailers_mut() {
            if let Some((key, value)) = this.trailer.take() {
                trailers.insert(key, value);
            }
        }
        Poll::Ready(Some(Ok(frame)))
    }

    fn is_end_stream(&self) -> bool {
        self.inner.is_end_stream()
    }

    fn size_hint(&self) -> http_body::SizeHint {
        self.inner.size_hint()
    }
}
