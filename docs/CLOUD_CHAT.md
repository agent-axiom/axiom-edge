# Cloud chat with your own keys

Axiom Edge talks directly to the selected provider. There is no Axiom account,
relay server, shared API key or application subscription. You supply your own
API key inside the app and pay the provider for API usage under your account.

## Providers and models

| Provider | Discovery | Text generation |
| --- | --- | --- |
| OpenAI | `GET https://api.openai.com/v1/models` | `POST https://api.openai.com/v1/responses`, SSE, `store: false` |
| Z.AI | `GET https://api.z.ai/api/paas/v4/models` if available for the account | `POST https://api.z.ai/api/paas/v4/chat/completions`, SSE |

The selector loads authenticated model IDs at runtime, supports search and
manual refresh, and keeps a dated on-device cache for offline browsing. A
cached entry is not a guarantee that a model is still available. There is no
bundled list of supposedly current models. If the provider does not expose a
catalog or the key lacks listing permission, enter the model ID from its
console manually. Generation access is checked by the provider when you send.

Model catalogs can include models for images, audio, embeddings or other
specialized tasks. This release implements **text conversations**; unsupported
models produce a visible provider error. No request is silently rerouted to a
different model or provider. Authentication, balance, quota, model and network
errors remain visible; there is no automatic billable generation retry.

Z.AI uses the general Model API and API/prepaid balance. Its separate Coding
Plan endpoint is not used for this general-purpose chat. An OpenAI ChatGPT
subscription does not include API usage credits.

## Conversations

Cloud conversations, their model/provider, instructions and drafts are saved
inside Application Support and survive an app restart. History supports search,
resume, rename and deletion. Each conversation keeps its provider/model; use a
new conversation to change them. Changing the active provider alone never
uploads an old conversation to that provider.

Sending includes the conversation context and instructions. Answers stream as
they arrive. Stop closes the active request, preserves partial text and marks
it as stopped; interrupted/failed answers remain visibly incomplete. Stopping
is local cancellation and cannot guarantee that the provider stops billing
immediately. There is no automatic retry. The retry/regenerate action is an
explicit new API request.

Saved history is versioned JSON. Writes are ordered and replace the archive
atomically. Invalid or unsupported history is preserved and blocks further
writes, with an error shown instead of resetting to an empty archive. Streaming
answers are checkpointed, then flushed on completion, cancellation and app
backgrounding. If the OS kills the process abruptly, the last checkpoint is
recovered as interrupted; the most recent unsaved tokens may be lost.

The original local model lab and its benchmarks are independent of cloud chat.
Its local chat remains in-memory. Cloud chat does not require downloading or
loading a GGUF/MNN model, and cloud history is readable without a network.

## Keys and privacy

- Keys are kept in iOS Keychain or Android Keystore-backed encrypted storage.
  They are not written into history, catalogs, exports, logs or source code.
- The key-entry field never reads a saved key back into the text input. Remove
  a saved key explicitly through the provider settings.
- iOS keys are accessible while the device is unlocked, device-bound and not
  synchronized to iCloud. Keychain data can survive uninstalling the app.
- Android app backup and device transfer are disabled/excluded so encrypted
  keys are not restored without the matching device Keystore.
- Conversations are ordinary JSON in the app's private sandbox, not a separate
  encrypted database. Device compromise or a user-shared export can expose them.
- Only the selected provider receives generation requests and their context.
  `store: false` disables OpenAI Response-object storage; it does **not** promise
  zero provider retention or override the provider's data policies.
- Markdown images do not load automatically. Following a link or sharing a
  conversation is an explicit user action.

Test APKs currently use a newly generated debug signing key on CI. An update
may require uninstalling the old build, which deletes local app files and
history. Export important conversations before uninstalling. A distributable
signed iOS app requires Apple signing; the CI archive is unsigned.

## Protocol references

- [OpenAI model listing](https://developers.openai.com/api/reference/resources/models/methods/list)
- [OpenAI Responses streaming](https://developers.openai.com/api/docs/guides/streaming-responses)
- [OpenAI response creation](https://developers.openai.com/api/reference/resources/responses/methods/create)
- [Z.AI Chat Completions](https://docs.z.ai/api-reference/llm/chat-completion)
- [Z.AI endpoint/account distinctions](https://zcode.z.ai/en/docs/configuration)
- [Secure storage implementation](https://pub.dev/packages/flutter_secure_storage)
