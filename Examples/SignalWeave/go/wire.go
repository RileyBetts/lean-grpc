package main

// Minimal protobuf wire helpers matching lean-grpc Proto.Wire field layout.
// Kept free of protoc so `go run .` works with only the grpc module.

import "fmt"

func appendVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

func appendKey(b []byte, field int, wt int) []byte {
	return appendVarint(b, uint64(field<<3|wt))
}

func appendString(b []byte, field int, s string) []byte {
	b = appendKey(b, field, 2)
	b = appendVarint(b, uint64(len(s)))
	return append(b, s...)
}

func appendBytes(b []byte, field int, p []byte) []byte {
	b = appendKey(b, field, 2)
	b = appendVarint(b, uint64(len(p)))
	return append(b, p...)
}

func appendUInt32(b []byte, field int, v uint32) []byte {
	return appendVarint(appendKey(b, field, 0), uint64(v))
}

func consumeVarint(b []byte, i int) (uint64, int, error) {
	var v uint64
	var shift uint
	for n := 0; n < 10; n++ {
		if i >= len(b) {
			return 0, i, fmt.Errorf("trunc varint")
		}
		c := b[i]
		i++
		v |= uint64(c&0x7f) << shift
		if c&0x80 == 0 {
			return v, i, nil
		}
		shift += 7
	}
	return 0, i, fmt.Errorf("varint overflow")
}

type fields map[int][][]byte

func decodeFields(b []byte) (fields, error) {
	out := fields{}
	i := 0
	for i < len(b) {
		key, ni, err := consumeVarint(b, i)
		if err != nil {
			return nil, err
		}
		i = ni
		fn := int(key >> 3)
		wt := int(key & 7)
		switch wt {
		case 0:
			v, ni, err := consumeVarint(b, i)
			if err != nil {
				return nil, err
			}
			i = ni
			buf := appendVarint(nil, v)
			out[fn] = append(out[fn], buf)
		case 2:
			ln, ni, err := consumeVarint(b, i)
			if err != nil {
				return nil, err
			}
			i = ni
			if i+int(ln) > len(b) {
				return nil, fmt.Errorf("trunc bytes")
			}
			out[fn] = append(out[fn], append([]byte(nil), b[i:i+int(ln)]...))
			i += int(ln)
		default:
			return nil, fmt.Errorf("unsupported wire type %d", wt)
		}
	}
	return out, nil
}

func fieldString(f fields, n int) string {
	vs := f[n]
	if len(vs) == 0 {
		return ""
	}
	return string(vs[0])
}

func fieldU32(f fields, n int) uint32 {
	vs := f[n]
	if len(vs) == 0 {
		return 0
	}
	v, _, err := consumeVarint(vs[0], 0)
	if err != nil {
		return 0
	}
	return uint32(v)
}

// Message codecs — field numbers must match Examples/SignalWeave/Protocol.lean.

func encodeTuneRequest(station string, khz uint32) []byte {
	b := appendString(nil, 1, station)
	if khz != 0 {
		b = appendUInt32(b, 2, khz)
	}
	return b
}

func decodeTuneReply(b []byte) (grant string, channel uint32, err error) {
	f, err := decodeFields(b)
	if err != nil {
		return "", 0, err
	}
	return fieldString(f, 1), fieldU32(f, 2), nil
}

func decodeBand(b []byte) (mhz, snrMilli uint32, err error) {
	f, err := decodeFields(b)
	if err != nil {
		return 0, 0, err
	}
	return fieldU32(f, 1), fieldU32(f, 2), nil
}

func encodeBurst(payload []byte) []byte {
	return appendBytes(nil, 1, payload)
}

func decodeUplinkAck(b []byte) (xorFold, count uint32, err error) {
	f, err := decodeFields(b)
	if err != nil {
		return 0, 0, err
	}
	return fieldU32(f, 1), fieldU32(f, 2), nil
}

func encodeWave(kind, note string) []byte {
	b := appendString(nil, 1, kind)
	return appendString(b, 2, note)
}

func decodeWave(b []byte) (kind, note string, err error) {
	f, err := decodeFields(b)
	if err != nil {
		return "", "", err
	}
	return fieldString(f, 1), fieldString(f, 2), nil
}

func foldXor(p []byte) uint32 {
	var x uint32
	for _, c := range p {
		x ^= uint32(c)
	}
	return x
}
