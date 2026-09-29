package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func prepared(t *testing.T, input string) *bridge {
	t.Helper()
	b := &bridge{}
	_, err := b.handle(frame{Op: "request", Model: "real-model", Body: json.RawMessage(input)})
	if err != nil {
		t.Fatal(err)
	}
	return b
}
func TestHistoryAndTools(t *testing.T) {
	b := prepared(t, `{"model":"main","stream":true,"instructions":"Be precise","input":[{"role":"user","content":[{"type":"input_text","text":"Check"}]},{"type":"reasoning","content":null,"summary":[]},{"type":"function_call","call_id":"call_1","name":"check","arguments":"{}"},{"type":"function_call_output","call_id":"call_1","output":"OK"}],"tools":[{"type":"function","name":"check","parameters":{"type":"object","properties":{}}},{"type":"custom","name":"apply_patch","format":{"type":"text"}}]}`)
	var chat map[string]any
	if err := json.Unmarshal(b.translated, &chat); err != nil {
		t.Fatal(err)
	}
	if chat["model"] != "real-model" || chat["input"] != nil {
		t.Fatalf("not Chat: %s", b.translated)
	}
	msgs := chat["messages"].([]any)
	last := msgs[len(msgs)-1].(map[string]any)
	if last["role"] != "tool" || last["tool_call_id"] != "call_1" || last["content"] != "OK" {
		t.Fatalf("tool result lost: %s", b.translated)
	}
	if len(chat["tools"].([]any)) != 2 {
		t.Fatalf("tools lost: %s", b.translated)
	}
}

const textStream = "data: {\"id\":\"chatcmpl_test\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"real-model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"id\":\"chatcmpl_test\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"real-model\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: [DONE]\r\n\r\n"

func TestStreamArbitraryByteSplits(t *testing.T) {
	for size := 1; size <= len(textStream); size++ {
		b := prepared(t, `{"model":"main","input":"Hello","stream":true}`)
		var out bytes.Buffer
		for offset := 0; offset < len(textStream); offset += size {
			end := offset + size
			if end > len(textStream) {
				end = len(textStream)
			}
			r, err := b.handle(frame{Op: "chunk", Data: []byte(textStream[offset:end])})
			if err != nil {
				t.Fatal(err)
			}
			for _, block := range r.Blocks {
				out.Write(block)
			}
		}
		r, err := b.handle(frame{Op: "finish"})
		if err != nil {
			t.Fatal(err)
		}
		for _, block := range r.Blocks {
			out.Write(block)
		}
		if strings.Count(out.String(), "event: response.completed") != 1 || !strings.Contains(out.String(), "你好") {
			t.Fatalf("split=%d incomplete: %s", size, out.String())
		}
	}
}
func TestMissingDoneRejected(t *testing.T) {
	b := prepared(t, `{"model":"main","input":"Hello","stream":true}`)
	withoutDone := strings.Split(textStream, "data: [DONE]")[0]
	r, err := b.handle(frame{Op: "chunk", Data: []byte(withoutDone)})
	if err != nil {
		t.Fatal(err)
	}
	for _, block := range r.Blocks {
		if bytes.Contains(block, []byte("event: response.completed")) {
			t.Fatal("premature completion")
		}
	}
	if _, err = b.handle(frame{Op: "finish"}); err == nil {
		t.Fatal("missing DONE accepted")
	}
}
func TestUnsupportedStateRejected(t *testing.T) {
	for _, body := range []string{`{"input":"a","previous_response_id":"resp_old"}`, `{"input":"a","conversation":"conv_old"}`, `{"input":[{"type":"compaction_trigger"}]}`} {
		b := &bridge{}
		if _, err := b.handle(frame{Op: "request", Model: "real", Body: json.RawMessage(body)}); err == nil {
			t.Fatal(body)
		}
	}
}
func TestNonstreamCustomTool(t *testing.T) {
	b := prepared(t, `{"model":"main","input":"Patch","tools":[{"type":"custom","name":"apply_patch","format":{"type":"text"}}]}`)
	r, err := b.handle(frame{Op: "response", Data: []byte(`{"id":"chatcmpl_test","object":"chat.completion","created":1,"model":"real-model","choices":[{"index":0,"message":{"role":"assistant","tool_calls":[{"id":"call_patch","type":"function","function":{"name":"apply_patch","arguments":"{\"input\":\"*** Begin Patch\\n*** End Patch\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":8,"completion_tokens":4,"total_tokens":12}}`)})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(r.Body, []byte(`"custom_tool_call"`)) || !bytes.Contains(r.Body, []byte(`"call_patch"`)) {
		t.Fatalf("custom tool lost: %s", r.Body)
	}
}
