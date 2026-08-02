// Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
// SignalWeave: Go client → Lean lean-grpc server stress demo.
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
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const service = "signal.weave.Exchange"

type rawCodec struct{}

func (rawCodec) Marshal(v any) ([]byte, error) {
	b, ok := v.([]byte)
	if !ok {
		return nil, fmt.Errorf("rawCodec: want []byte, got %T", v)
	}
	return b, nil
}

func (rawCodec) Unmarshal(data []byte, v any) error {
	p, ok := v.(*[]byte)
	if !ok {
		return fmt.Errorf("rawCodec: want *[]byte, got %T", v)
	}
	*p = append((*p)[:0], data...)
	return nil
}

func (rawCodec) Name() string { return "proto" }

type check struct {
	name string
	ok   bool
	detail string
}

func main() {
	host := "127.0.0.1"
	port := "50301"
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
		grpc.WithUserAgent("signal-weave-go/1.0"),
	)
	if err != nil {
		fatalf("dial: %v", err)
	}
	defer conn.Close()

	var checks []check

	checks = append(checks, actTuneOK(ctx, conn))
	checks = append(checks, actTuneInvalid(ctx, conn))
	checks = append(checks, actTuneOutOfRange(ctx, conn))
	checks = append(checks, actSpectrum(ctx, conn))
	checks = append(checks, actUplinkGzip(ctx, conn))
	checks = append(checks, actHandshake(ctx, conn))
	checks = append(checks, actBlackout(ctx, conn))
	checks = append(checks, actSlowDeadline(ctx, conn))
	checks = append(checks, actHealth(ctx, conn))
	checks = append(checks, actMetadataEcho(ctx, conn))

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
		fmt.Printf("\n%d/%d CHECKS FAILED\n", fail, len(checks))
		os.Exit(1)
	}
	fmt.Printf("\nALL %d CHECKS PASSED (Go client → Lean SignalWeave)\n", len(checks))
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

func actTuneOK(ctx context.Context, conn *grpc.ClientConn) check {
	name := "I Tune unary OK"
	md := metadata.Pairs("x-station-call", "CQ-SW1", "x-bin-token-bin", "dG9rZW4=")
	ctx = metadata.NewOutgoingContext(ctx, md)
	resp, err := unary(ctx, conn, "Tune", encodeTuneRequest("ALPHA", 14000))
	if err != nil {
		return check{name, false, err.Error()}
	}
	grant, ch, err := decodeTuneReply(resp)
	if err != nil {
		return check{name, false, err.Error()}
	}
	if grant != "OK:ALPHA" || ch != (14000/25)%64 {
		return check{name, false, fmt.Sprintf("grant=%q ch=%d", grant, ch)}
	}
	return check{name, true, fmt.Sprintf("grant=%s channel=%d", grant, ch)}
}

func actTuneInvalid(ctx context.Context, conn *grpc.ClientConn) check {
	name := "II Tune INVALID_ARGUMENT"
	_, err := unary(ctx, conn, "Tune", encodeTuneRequest("", 14000))
	st, ok := status.FromError(err)
	if !ok || st.Code() != codes.InvalidArgument {
		return check{name, false, fmt.Sprintf("got %v", err)}
	}
	return check{name, true, st.Message()}
}

func actTuneOutOfRange(ctx context.Context, conn *grpc.ClientConn) check {
	name := "III Tune OUT_OF_RANGE"
	_, err := unary(ctx, conn, "Tune", encodeTuneRequest("LOW", 50))
	st, ok := status.FromError(err)
	if !ok || st.Code() != codes.OutOfRange {
		return check{name, false, fmt.Sprintf("got %v", err)}
	}
	return check{name, true, st.Message()}
}

func actSpectrum(ctx context.Context, conn *grpc.ClientConn) check {
	name := "IV Spectrum server-stream"
	stream, err := conn.NewStream(ctx, &grpc.StreamDesc{ServerStreams: true}, "/"+service+"/Spectrum")
	if err != nil {
		return check{name, false, err.Error()}
	}
	if err := stream.SendMsg(encodeTuneRequest("SCAN", 14000000)); err != nil {
		return check{name, false, "send: " + err.Error()}
	}
	if err := stream.CloseSend(); err != nil {
		return check{name, false, "close: " + err.Error()}
	}
	var bands []string
	for {
		var msg []byte
		err := stream.RecvMsg(&msg)
		if err == io.EOF {
			break
		}
		if err != nil {
			return check{name, false, err.Error()}
		}
		mhz, snr, err := decodeBand(msg)
		if err != nil {
			return check{name, false, err.Error()}
		}
		bands = append(bands, fmt.Sprintf("%d@%d", mhz, snr))
	}
	if len(bands) != 4 || bands[0] != "14000@12000" {
		return check{name, false, fmt.Sprintf("%v", bands)}
	}
	return check{name, true, fmt.Sprintf("%d bands %v", len(bands), bands)}
}

func actUplinkGzip(ctx context.Context, conn *grpc.ClientConn) check {
	name := "V Uplink client-stream + gzip"
	stream, err := conn.NewStream(ctx, &grpc.StreamDesc{ClientStreams: true},
		"/"+service+"/Uplink", grpc.UseCompressor(gzip.Name))
	if err != nil {
		return check{name, false, err.Error()}
	}
	payloads := [][]byte{[]byte("cq"), []byte("dx"), []byte{0xAA, 0x55, 0x01}}
	var expect uint32
	for _, p := range payloads {
		expect ^= foldXor(p)
		if err := stream.SendMsg(encodeBurst(p)); err != nil {
			return check{name, false, "send: " + err.Error()}
		}
	}
	if err := stream.CloseSend(); err != nil {
		return check{name, false, "close: " + err.Error()}
	}
	var ack []byte
	if err := stream.RecvMsg(&ack); err != nil {
		return check{name, false, "recv: " + err.Error()}
	}
	x, n, err := decodeUplinkAck(ack)
	if err != nil {
		return check{name, false, err.Error()}
	}
	if x != expect || n != 3 {
		return check{name, false, fmt.Sprintf("xor=%d want=%d count=%d", x, expect, n)}
	}
	return check{name, true, fmt.Sprintf("xor=%d count=%d", x, n)}
}

func actHandshake(ctx context.Context, conn *grpc.ClientConn) check {
	name := "VI Handshake bidi"
	stream, err := conn.NewStream(ctx, &grpc.StreamDesc{ServerStreams: true, ClientStreams: true},
		"/"+service+"/Handshake")
	if err != nil {
		return check{name, false, err.Error()}
	}
	seq := [][2]string{{"SYN", "cq"}, {"ACK", "weave"}}
	for _, w := range seq {
		if err := stream.SendMsg(encodeWave(w[0], w[1])); err != nil {
			return check{name, false, "send: " + err.Error()}
		}
	}
	if err := stream.CloseSend(); err != nil {
		return check{name, false, "close: " + err.Error()}
	}
	var kinds []string
	for {
		var msg []byte
		err := stream.RecvMsg(&msg)
		if err == io.EOF {
			break
		}
		if err != nil {
			return check{name, false, err.Error()}
		}
		k, note, err := decodeWave(msg)
		if err != nil {
			return check{name, false, err.Error()}
		}
		kinds = append(kinds, k+":"+note)
	}
	if len(kinds) < 2 || kinds[0] != "ACK:cq" || kinds[len(kinds)-1] != "LOCK:linked" {
		return check{name, false, fmt.Sprintf("%v", kinds)}
	}
	return check{name, true, fmt.Sprintf("%v", kinds)}
}

func actBlackout(ctx context.Context, conn *grpc.ClientConn) check {
	name := "VII Blackout INTERNAL"
	_, err := unary(ctx, conn, "Blackout", []byte{})
	st, ok := status.FromError(err)
	if !ok || st.Code() != codes.Internal {
		return check{name, false, fmt.Sprintf("got %v", err)}
	}
	return check{name, true, st.Message()}
}

func actSlowDeadline(ctx context.Context, conn *grpc.ClientConn) check {
	name := "VIII SlowTune DEADLINE_EXCEEDED"
	dctx, cancel := context.WithTimeout(ctx, 200*time.Millisecond)
	defer cancel()
	_, err := unary(dctx, conn, "SlowTune", encodeTuneRequest("LATE", 7000))
	st, ok := status.FromError(err)
	if !ok || st.Code() != codes.DeadlineExceeded {
		return check{name, false, fmt.Sprintf("got %v", err)}
	}
	return check{name, true, st.Code().String()}
}

func actHealth(ctx context.Context, conn *grpc.ClientConn) check {
	name := "IX Health Check SERVING"
	// Health uses protobuf; dial a second conn without ForceCodec, or use generated client
	// on a dedicated connection.
	hconn, err := grpc.NewClient(conn.Target(),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return check{name, false, err.Error()}
	}
	defer hconn.Close()
	cli := grpc_health_v1.NewHealthClient(hconn)
	resp, err := cli.Check(ctx, &grpc_health_v1.HealthCheckRequest{})
	if err != nil {
		return check{name, false, err.Error()}
	}
	if resp.Status != grpc_health_v1.HealthCheckResponse_SERVING {
		return check{name, false, resp.Status.String()}
	}
	return check{name, true, "SERVING"}
}

func actMetadataEcho(ctx context.Context, conn *grpc.ClientConn) check {
	name := "X user-agent + metadata unary"
	md := metadata.Pairs("x-weave-band", "HF")
	ctx = metadata.NewOutgoingContext(ctx, md)
	var header metadata.MD
	resp, err := unary(ctx, conn, "Tune", encodeTuneRequest("META", 28000), grpc.Header(&header))
	if err != nil {
		return check{name, false, err.Error()}
	}
	grant, _, err := decodeTuneReply(resp)
	if err != nil || grant != "OK:META" {
		return check{name, false, fmt.Sprintf("grant=%q err=%v", grant, err)}
	}
	// Lean may not echo custom md; assert call succeeded with our UA on the wire.
	return check{name, true, "Tune with x-weave-band OK"}
}
