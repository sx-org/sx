use std::convert::Infallible;
use std::env;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use bytes::Bytes;
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;

type Body = Full<Bytes>;

async fn handle(
    _req: Request<Incoming>,
    count: Arc<AtomicU64>,
) -> Result<Response<Body>, Infallible> {
    let served = count.fetch_add(1, Ordering::Relaxed) + 1;
    if served % 10000 == 0 {
        eprintln!("[http] served {served} requests");
    }

    Ok(Response::builder()
        .header("content-type", "text/plain")
        .body(Full::new(Bytes::from_static(b"ok")))
        .unwrap())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let port = env::var("PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(8084);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = TcpListener::bind(addr).await?;
    let count = Arc::new(AtomicU64::new(0));

    eprintln!("listening on http://localhost:{port}");

    loop {
        let (stream, _) = listener.accept().await?;
        let io = TokioIo::new(stream);
        let count = Arc::clone(&count);

        tokio::spawn(async move {
            let service = service_fn(move |req| handle(req, Arc::clone(&count)));
            if let Err(err) = http1::Builder::new().serve_connection(io, service).await {
                eprintln!("[http] connection error: {err}");
            }
        });
    }
}
