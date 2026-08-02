// Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
// Go client side of the peer-framing matrix against the Lean FramingMatrix server.
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/encoding/gzip"
	"google.golang.org/grpc/status"
)

const service = "framing.matrix.Probe"

type rawCodec struct{}

func (rawCodec) Marshal(v any) ([]byte, error) {
	b, ok := v.([]byte)
	if !ok {
		return nil, fmt.Errorf("want []byte, got %T", v)
	}
	return b, nil
}

func (rawCodec) Unmarshal(data []byte, v any) error {
	p, ok := v.(*[]byte)
	if !ok {
		return fmt.Errorf("want *[]byte, got %T", v)
	}
	*p = append((*p)[:0], data...)
	return nil
}

func (rawCodec) Name() string { return "proto" }

type check struct {
	name, detail string
	ok           bool
}

func main() {
	host, port := "127.0.0.1", "50310"
	if len(os.Args) > 1 {
		host = os.Args[1]
	}
	if len(os.Args) > 2 {
		port = os.Args[2]
	}
	addr := fmt.Sprintf("%s:%s", host, port)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.ForceCodec(rawCodec{})),
		grpc.WithUserAgent("framing-matrix-go/1.0"),
	)
	if err != nil {
		fatalf("dial: %v", err)
	}
	defer conn.Close()

	var checks []check
	checks = append(checks, goEcho(ctx, conn, false))
	checks = append(checks, goEcho(ctx, conn, true))
	checks = append(checks, goFanOut(ctx, conn))
	checks = append(checks, goCollectGzip(ctx, conn))
	checks = append(checks, goRelay(ctx, conn))
	checks = append(checks, goDeadline(ctx, conn))
	checks = append(checks, goCancel(ctx, conn))

	fail := 0
	for _, c := range checks {
		mark := "PASS"
		if !c.ok {
			mark = "FAIL"
			fail++
		}
		if c.detail != "" {
			fmt.Printf("[%s] %s — %s\n", mark, c.name, c.detail)
		} else {
			fmt.Printf("[%s] %s\n", mark, c.name)
		}
	}
	if fail > 0 {
		fmt.Printf("\n%d/%d GO FRAMING CHECKS FAILED\n", fail, len(checks))
		os.Exit(1)
	}
	fmt.Printf("\nALL %d GO FRAMING CHECKS PASSED\n", len(checks))
}

func fatalf(f string, a ...any) {
	fmt.Fprintf(os.Stderr, f+"\n", a...)
	os.Exit(1)
}

func unary(ctx context.Context, conn *grpc.ClientConn, method string, req []byte, opts ...grpc.CallOption) ([]byte, error) {
	var resp []byte
	err := conn.Invoke(ctx, "/"+service+"/"+method, req, &resp, opts...)
	return resp, err
}

func goEcho(ctx context.Context, conn *grpc.ClientConn, useGzip bool) check {
	name := "go.echo.identity"
	var opts []grpc.CallOption
	if useGzip {
		name = "go.echo.gzip"
		opts = append(opts, grpc.UseCompressor(gzip.Name))
	}
	resp, err := unary(ctx, conn, "Echo", encodeBlob("hi"), opts...)
	if err != nil {
		return check{name, err.Error(), false}
	}
	text, err := decodeBlob(resp)
	if err != nil || text != "echo:hi" {
		return check{name, fmt.Sprintf("%q err=%v", text, err), false}
	}
	return check{name, text, true}
}

func goFanOut(ctx context.Context, conn *grpc.ClientConn) check {
	name := "go.fanout.server_stream"
	stream, err := conn.NewStream(ctx, &grpc.StreamDesc{ServerStreams: true}, "/"+service+"/FanOut")
	if err != nil {
		return check{name, err.Error(), false}
	}
	if err := stream.SendMsg(encodeBlob("scan")); err != nil {
		return check{name, "send: " + err.Error(), false}
	}
	if err := stream.CloseSend(); err != nil {
		return check{name, "close: " + err.Error(), false}
	}
	var texts []string
	for {
		var msg []byte
		err := stream.RecvMsg(&msg)
		if err == io.EOF {
			break
		}
		if err != nil {
			return check{name, err.Error(), false}
		}
		t, err := decodeBlob(msg)
		if err != nil {
			return check{name, err.Error(), false}
		}
		texts = append(texts, t)
	}
	if len(texts) != 3 || texts[0] != "scan:1" || texts[2] != "scan:3" {
		return check{name, fmt.Sprintf("%v", texts), false}
	}
	return check{name, fmt.Sprintf("%v", texts), true}
}

func goCollectGzip(ctx context.Context, conn *grpc.ClientConn) check {
	name := "go.collect.gzip_client_stream"
	stream, err := conn.NewStream(ctx, &grpc.StreamDesc{ClientStreams: true},
		"/"+service+"/Collect", grpc.UseCompressor(gzip.Name))
	if err != nil {
		return check{name, err.Error(), false}
	}
	texts := []string{"aa", "bb", "cc"}
	var expect uint32
	for _, t := range texts {
		expect ^= foldXorString(t)
		if err := stream.SendMsg(encodeBlob(t)); err != nil {
			return check{name, "send: " + err.Error(), false}
		}
	}
	if err := stream.CloseSend(); err != nil {
		return check{name, "close: " + err.Error(), false}
	}
	var ack []byte
	if err := stream.RecvMsg(&ack); err != nil {
		return check{name, "recv: " + err.Error(), false}
	}
	n, x, err := decodeTally(ack)
	if err != nil || n != 3 || x != expect {
		return check{name, fmt.Sprintf("n=%d xor=%d want=%d err=%v", n, x, expect, err), false}
	}
	return check{name, fmt.Sprintf("xor=%d", x), true}
}

func goRelay(ctx context.Context, conn *grpc.ClientConn) check {
	name := "go.relay.bidi_empty_halfclose"
	stream, err := conn.NewStream(ctx, &grpc.StreamDesc{ServerStreams: true, ClientStreams: true},
		"/"+service+"/Relay")
	if err != nil {
		return check{name, err.Error(), false}
	}
	for _, t := range []string{"one", "two"} {
		if err := stream.SendMsg(encodeBlob(t)); err != nil {
			return check{name, "send: " + err.Error(), false}
		}
	}
	// grpc-go CloseSend → empty DATA + END_STREAM (the half-close bug class).
	if err := stream.CloseSend(); err != nil {
		return check{name, "close: " + err.Error(), false}
	}
	var texts []string
	for {
		var msg []byte
		err := stream.RecvMsg(&msg)
		if err == io.EOF {
			break
		}
		if err != nil {
			return check{name, err.Error(), false}
		}
		t, err := decodeBlob(msg)
		if err != nil {
			return check{name, err.Error(), false}
		}
		texts = append(texts, t)
	}
	if len(texts) != 2 || texts[0] != "R:one" || texts[1] != "R:two" {
		return check{name, fmt.Sprintf("%v", texts), false}
	}
	return check{name, fmt.Sprintf("%v", texts), true}
}

func goDeadline(ctx context.Context, conn *grpc.ClientConn) check {
	name := "go.slow.deadline"
	dctx, cancel := context.WithTimeout(ctx, 50*time.Millisecond)
	defer cancel()
	_, err := unary(dctx, conn, "SlowEcho", encodeBlob("x"))
	st, ok := status.FromError(err)
	if !ok || st.Code() != codes.DeadlineExceeded {
		return check{name, fmt.Sprintf("got %v", err), false}
	}
	return check{name, st.Code().String(), true}
}

func goCancel(ctx context.Context, conn *grpc.ClientConn) check {
	// FanOut buffers all replies in one response body, so cancel-after-first-recv
	// often still drains remaining messages with err=nil. Cancel a slow unary instead.
	name := "go.slow.cancel"
	cctx, cancel := context.WithCancel(ctx)
	done := make(chan error, 1)
	go func() {
		_, err := unary(cctx, conn, "SlowEcho", encodeBlob("c"))
		done <- err
	}()
	time.Sleep(30 * time.Millisecond)
	cancel()
	err := <-done
	st, ok := status.FromError(err)
	if err == nil {
		return check{name, "expected cancel error", false}
	}
	if ok && (st.Code() == codes.Canceled || st.Code() == codes.DeadlineExceeded) {
		return check{name, st.Code().String(), true}
	}
	if cctx.Err() != nil {
		return check{name, "context canceled", true}
	}
	return check{name, fmt.Sprintf("got %v", err), false}
}
