# iOS Memory and Context Limits

Local models on iPhone are constrained by physical memory, runtime buffers, and KV cache. The model's theoretical context window is only one part of the story.

## The practical constraint

On a phone, memory is shared by:

- model weights
- KV cache
- tokenizer and runtime state
- Metal / GPU buffers
- image and audio buffers
- app UI state
- the operating system

When context grows, KV cache grows with it. That is why a model can advertise a large theoretical context window but still feel unreliable or slow on a phone at much smaller windows.

## Product implication

PhoneClaw is designed around practical local-agent tasks:

- short and medium conversations
- tool calls
- schedule and personal data queries
- translation
- image understanding
- realtime web summaries when explicitly requested

It is not positioned as a cloud-scale long-context replacement. That boundary is intentional.

## Why 4096 is reasonable today

PhoneClaw currently favors a conservative context window because the app must leave room for:

- model weights
- KV cache
- image or audio input
- tool-call state
- chat history storage
- UI rendering
- iOS memory pressure

A larger context can work in narrow cases, but reliability matters more than headline context size for a mobile Agent.

## What will change over time

This is not a permanent limit. The comfortable context window can improve as:

- iPhones ship with more RAM
- runtimes reduce memory overhead
- KV cache becomes more efficient
- quantization improves
- model architectures become more memory-friendly
- tool routing reduces the need to keep everything in context

## Design strategy

PhoneClaw reduces pressure by using:

- focused Skills instead of one giant prompt
- explicit tool routing
- history trimming
- cache cleanup
- model switching
- local tools for structured data instead of forcing the LLM to remember everything

The core idea: use the model for reasoning and language, use native tools for durable data.

## Useful links

- [On-device Gemma on iPhone](ON_DEVICE_GEMMA.md)
- [PhoneClaw Skill System](SKILL_SYSTEM.md)
- [README](../README.md)
