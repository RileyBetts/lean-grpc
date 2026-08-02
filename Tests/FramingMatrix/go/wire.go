// Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
package main

import "fmt"

func appendVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

func appendKey(b []byte, field, wt int) []byte {
	return appendVarint(b, uint64(field<<3|wt))
}

func appendString(b []byte, field int, s string) []byte {
	b = appendKey(b, field, 2)
	b = appendVarint(b, uint64(len(s)))
	return append(b, s...)
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
			out[fn] = append(out[fn], appendVarint(nil, v))
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
			return nil, fmt.Errorf("unsupported wt %d", wt)
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

func encodeBlob(text string) []byte {
	return appendString(nil, 1, text)
}

func decodeBlob(b []byte) (string, error) {
	f, err := decodeFields(b)
	if err != nil {
		return "", err
	}
	return fieldString(f, 1), nil
}

func decodeTally(b []byte) (count, xorFold uint32, err error) {
	f, err := decodeFields(b)
	if err != nil {
		return 0, 0, err
	}
	return fieldU32(f, 1), fieldU32(f, 2), nil
}

func foldXorString(s string) uint32 {
	var x uint32
	for i := 0; i < len(s); i++ {
		x ^= uint32(s[i])
	}
	return x
}
