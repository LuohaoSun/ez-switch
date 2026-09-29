// Reuses CLIProxyAPI's translator SDK. No credentials or networking. One request per process.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	translator "github.com/router-for-me/CLIProxyAPI/v8/sdk/translator"
	_ "github.com/router-for-me/CLIProxyAPI/v8/sdk/translator/builtin"
	"io"
	"os"
)

type frame struct {
	Op    string          `json:"op"`
	Model string          `json:"model,omitempty"`
	Body  json.RawMessage `json:"body,omitempty"`
	Data  []byte          `json:"data,omitempty"`
}
type reply struct {
	OK     bool            `json:"ok"`
	Error  string          `json:"error,omitempty"`
	Body   json.RawMessage `json:"body,omitempty"`
	Blocks [][]byte        `json:"blocks"`
}
type bridge struct {
	original, translated  []byte
	model                 string
	param                 any
	ready, done, terminal bool
	pending               []byte
}

func (b *bridge) translateEvent(data []byte) ([][]byte, error) {
	data = bytes.TrimSpace(data)
	if bytes.Equal(data, []byte("[DONE]")) {
		b.terminal = true
	} else if !json.Valid(data) {
		return nil, fmt.Errorf("invalid Chat SSE data")
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(data, &obj) == nil && obj["error"] != nil {
		return nil, fmt.Errorf("upstream stream error: %s", obj["error"])
	}
	return translator.TranslateStream(context.Background(), translator.FormatOpenAI,
		translator.FormatOpenAIResponse, b.model, b.original, b.translated, data, &b.param), nil
}
func (b *bridge) consume(data []byte, flush bool) ([][]byte, error) {
	b.pending = append(b.pending, data...)
	var blocks [][]byte
	for {
		end, width := bytes.Index(b.pending, []byte("\n\n")), 2
		if crlf := bytes.Index(b.pending, []byte("\r\n\r\n")); crlf >= 0 && (end < 0 || crlf < end) {
			end, width = crlf, 4
		}
		if end < 0 {
			if !flush || len(bytes.TrimSpace(b.pending)) == 0 {
				break
			}
			end, width = len(b.pending), 0
		}
		event := append([]byte(nil), b.pending[:end]...)
		b.pending = b.pending[end+width:]
		var lines [][]byte
		for _, line := range bytes.Split(event, []byte("\n")) {
			line = bytes.TrimSuffix(line, []byte("\r"))
			if bytes.HasPrefix(line, []byte("data:")) {
				lines = append(lines, bytes.TrimSpace(line[5:]))
			}
		}
		if len(lines) == 0 {
			continue
		}
		out, err := b.translateEvent(bytes.Join(lines, []byte("\n")))
		if err != nil {
			return nil, err
		}
		blocks = append(blocks, out...)
	}
	if len(b.pending) > 16*1024*1024 {
		return nil, fmt.Errorf("Chat SSE event too large")
	}
	return blocks, nil
}
func (b *bridge) handle(f frame) (reply, error) {
	switch f.Op {
	case "request":
		if b.ready {
			return reply{}, fmt.Errorf("request already initialized")
		}
		var obj map[string]any
		if err := json.Unmarshal(f.Body, &obj); err != nil {
			return reply{}, err
		}
		if obj == nil || f.Model == "" {
			return reply{}, fmt.Errorf("invalid Responses request")
		}
		if previous, ok := obj["previous_response_id"].(string); ok && previous != "" {
			return reply{}, fmt.Errorf("Chat bridge requires full input history; previous_response_id is unsupported")
		}
		if obj["conversation"] != nil {
			return reply{}, fmt.Errorf("Chat bridge requires full input history; conversation is unsupported")
		}
		if obj["compaction_trigger"] != nil {
			return reply{}, fmt.Errorf("remote compaction is unsupported; use Codex local compaction")
		}
		if input, ok := obj["input"].([]any); ok {
			for _, item := range input {
				if v, ok := item.(map[string]any); ok && (v["type"] == "compaction_trigger" || v["type"] == "compaction") {
					return reply{}, fmt.Errorf("remote compaction items are unsupported")
				}
			}
		}
		stream, _ := obj["stream"].(bool)
		b.original, b.model = append([]byte(nil), f.Body...), f.Model
		b.translated = translator.TranslateRequest(translator.FormatOpenAIResponse, translator.FormatOpenAI, f.Model, f.Body, stream)
		if !json.Valid(b.translated) {
			return reply{}, fmt.Errorf("translator returned invalid JSON")
		}
		b.ready = true
		return reply{OK: true, Body: b.translated}, nil
	case "chunk":
		if !b.ready || b.done {
			return reply{}, fmt.Errorf("bridge is not active")
		}
		out, err := b.consume(f.Data, false)
		return reply{OK: true, Blocks: out}, err
	case "finish":
		if !b.ready || b.done {
			return reply{}, fmt.Errorf("bridge is not active")
		}
		out, err := b.consume(nil, true)
		if err != nil {
			return reply{}, err
		}
		if !b.terminal {
			return reply{}, fmt.Errorf("upstream Chat stream ended without [DONE]")
		}
		b.done = true
		return reply{OK: true, Blocks: out}, nil
	case "response":
		if !b.ready || b.done {
			return reply{}, fmt.Errorf("bridge is not active")
		}
		if !json.Valid(f.Data) {
			return reply{}, fmt.Errorf("invalid Chat response JSON")
		}
		body := translator.TranslateNonStream(context.Background(), translator.FormatOpenAI, translator.FormatOpenAIResponse, b.model, b.original, b.translated, f.Data, &b.param)
		var original map[string]json.RawMessage
		if json.Unmarshal(b.original, &original) == nil && original["model"] != nil {
			var response map[string]json.RawMessage
			if json.Unmarshal(body, &response) == nil {
				response["model"] = original["model"]
				body, _ = json.Marshal(response)
			}
		}
		b.done = true
		return reply{OK: true, Body: body}, nil
	default:
		return reply{}, fmt.Errorf("unknown operation")
	}
}
func serve(input io.Reader, output io.Writer) error {
	decoder, encoder := json.NewDecoder(input), json.NewEncoder(output)
	b := &bridge{}
	for {
		var f frame
		if err := decoder.Decode(&f); err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		r, err := b.handle(f)
		if err != nil {
			r = reply{OK: false, Error: err.Error()}
		}
		if err := encoder.Encode(r); err != nil {
			return err
		}
	}
}
func main() {
	if err := serve(bufio.NewReader(os.Stdin), os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
