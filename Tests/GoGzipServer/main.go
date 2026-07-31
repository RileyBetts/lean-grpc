// Gzip-enabled gRPC interop TestService server for Lean client_compressed_* cases.
// The stock `go install .../interop/server` binary does not register the gzip codec.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"

	"google.golang.org/grpc"
	_ "google.golang.org/grpc/encoding/gzip"
	"google.golang.org/grpc/interop"
	testgrpc "google.golang.org/grpc/interop/grpc_testing"
)

func main() {
	port := flag.Int("port", 10005, "listen port")
	flag.Parse()
	lis, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	s := grpc.NewServer()
	testgrpc.RegisterTestServiceServer(s, interop.NewTestServer())
	log.Printf("gzip interop server on %s", lis.Addr())
	if err := s.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}
