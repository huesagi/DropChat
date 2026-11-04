# DropChat

DropChat puts a chat with a large language model on Droppy's shelf, with an optional floating window that stays above full-screen apps. Bring your own API key; connect MCP servers, agent skills and web search for tools; attach files or whatever is selected in Finder.

## Features

- **Providers:** OpenAI, Anthropic, Google Gemini, OpenRouter, and any OpenAI-compatible endpoint (Ollama, LM Studio, vLLM, llama.cpp…). Several accounts at once, switchable per chat, with streaming, reasoning summaries and live model lists.
- **MCP tools:** local servers started as commands (`npx`, `uvx`, any binary) and remote servers over Streamable HTTP. Paste an `mcpServers` JSON block to import many at once.
- **Agent skills:** point DropChat at folders of skills (each a folder with a `SKILL.md`, e.g. `~/.claude/skills`). The model sees every skill's name and description, loads instructions on demand, reads bundled files and, if you allow it, runs bundled scripts.
- **Web:** `web_search` through Exa or Perplexity (ranked results or a Sonar answer with sources) and `web_fetch` to read pages, through Exa's crawler or directly.
- **Files:** attach with the paperclip, drop files on the chat, or pull in Finder's selection (optional, off by default). Images, PDFs (sent natively where the API reads PDFs, as extracted text otherwise), text and code files, and folder listings.
- **Shortcut:** Option-Shift-Space (rebindable on Droppy's Shortcuts page) shows or hides DropChat from any app: the chat in the notch, or the floating window when that is on.
- **Floating window:** off by default. A chat window that joins every Space and floats over full-screen apps. It shares the conversation with the shelf.
- **Keyboard:** Return sends, Shift-Return adds a line, ⌘N starts a new chat, ⌘. stops an answer. The prompt field takes focus whenever the chat opens.
- **Fresh chats:** optionally start a new chat when DropChat is reopened after being closed for a time you choose, in seconds or minutes.
- **History:** chats are saved on this Mac in DropChat's own folder; turn it off in settings.

## Privacy and safety

- API keys, MCP environment variables and MCP headers are stored in the macOS Keychain, never in preferences. Each has a Remove button.
- Every tool call asks first unless you allow it for the chat or mark an MCP server as trusted. Tools a server marks destructive, and every skill script, ask every time.
- Nothing leaves your Mac except the requests you make to the services you configured.

## Architecture

```
Sources/
  DropChatCore/   Foundation-only engine, unit-tested
    Model/          JSONValue, messages, content parts, tool specs
    Providers/      LLMProvider protocol, OpenAI-compatible / Anthropic / Gemini wire formats, SSE, HTTP
    Tools/          ChatTool + ToolSource protocols, ToolRegistry, approvals
    Agent/          AgentLoop (stream -> tools -> repeat), SystemPromptBuilder, ChatEngine
    MCP/            JSON-RPC client, stdio and Streamable HTTP transports, MCP tool source
    Web/            WebSearchProvider / WebFetchProvider, Exa, Perplexity, direct fetcher
    Skills/         SKILL.md discovery, frontmatter, skill tools, script runner
    Attachments/    file loading (images, PDFs, text), Finder selection
    Storage/        Keychain, settings, conversation history
  DropChat/       the droplet: DroppyKit surfaces, SwiftUI, AppKit
    DropChatDroplet.swift   lifecycle, shelf widget, settings pane, shortcut
    AppModel.swift          composition root
    ChatSession.swift       one live chat shared by every surface
    UI/                     chat views, floating panel
    Settings/               settings pane
  DropChatHarness/  `droppykit run` entry
Tests/DropChatCoreTests/
```

### Extending

| To add | Do this |
| --- | --- |
| An OpenAI-compatible service preset | Add a `ProviderKind` case with its name, base URL and suggested models. |
| A new LLM API | Implement `LLMProvider` (encoder + stream decoder), add a `WireFormat`, `register` it in `ProviderFactory`. |
| A family of tools | Implement `ToolSource` (and `ChatTool`s), write a `ToolSourceBuilder` from settings, add it to `AppModel.toolSourceBuilders`. |
| A web backend | Conform to `WebSearchProvider` / `WebFetchProvider`, add a `WebBackend` case. |
| Context in the system prompt | Conform a source to `PromptContributor`. |
| A new chat surface | Bind a view to `AppModel.session` (`ChatView` works anywhere). |

## Building

DropChat is a Droplet built with [DroppyKit](https://gitlab.com/droppyformac1/droppykit). With the SDK's `Scripts` folder on your `PATH`:

```bash
droppykit build
```

```bash
droppykit validate
```

```bash
droppykit run -- --shots ./shots --report ./shots/report.json
```

Then copy `.build/DropChat.droplet` to `~/Library/Application Support/Droppy Playground/Droplets/dropchat/` and relaunch Droppy Playground. `swift test` runs the engine's unit tests. Never ship a bundle from a bare `swift build`.

## Credits

No third-party code. Placeholder icon and avatar are the DroppyKit scaffold's.

## License

MIT
