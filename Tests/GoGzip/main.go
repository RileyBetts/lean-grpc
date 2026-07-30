// Peer gzip unary round-trip against a Lean (or any) gRPC TestService/UnaryCall.
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/encoding/gzip"
	"google.golang.org/grpc/interop/grpc_testing"
)

func main() {
	host := "127.0.0.1"
	port := "10000"
	if len(os.Args) > 1 {
		host = os.Args[1]
	}
	if len(os.Args) > 2 {
		port = os.Args[2]
	}
	addr := fmt.Sprintf("%s:%s", host, port)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := grpc.DialContext(ctx, addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.UseCompressor(gzip.Name)),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dial: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()
	client := grpc_testing.NewTestServiceClient(conn)
	req := &grpc_testing.SimpleRequest{
		ResponseSize: 16,
		Payload:      &grpc_testing.Payload{Body: make([]byte, 32)},
	}
	resp, err := client.UnaryCall(ctx, req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "UnaryCall gzip: %v\n", err)
		os.Exit(1)
	}
	if len(resp.GetPayload().GetBody()) != 16 {
		fmt.Fprintf(os.Stderr, "bad response size %d\n", len(resp.GetPayload().GetBody()))
		os.Exit(1)
	}
	fmt.Println("go→lean gzip unary OK")
}
