import QtQuick
import qs.modules.common.functions as CF

/**
 * ApiStrategy that talks to a local `opencode serve` server.
 *
 * opencode is an autonomous coding agent, so it manages its own tool
 * execution. This strategy just forwards each user turn and streams back the
 * resulting text (and reasoning) so it can be shown in the sidebar chat.
 *
 * opencode's HTTP message API only accepts plain `text` parts for the current
 * (implicitly-user) message and does not accept full conversation history in
 * the request body, so this strategy reuses a single persistent opencode
 * session (stored in a file) and sends only the newest user message each time.
 * The sidebar chat UI remains the authoritative visible history.
 *
 * ApiStrategy is a bare QtObject (functions only), so the opencode server is
 * started lazily from within the generated bash script rather than as a QML
 * Process child.
 */
ApiStrategy {
    id: root
    property bool isThinking: false

    /// Fixed local port for the headless opencode server
    property int serverPort: 4100
    readonly property string serverBase: "http://127.0.0.1:" + root.serverPort

    // Protocol markers used between the bash polling script and parseResponseLine.
    readonly property string textPrefix: "OC|TEXT|"
    readonly property string thinkPrefix: "OC|THINK|"
    readonly property string donePrefix: "OC|DONE|"
    readonly property string errPrefix: "OC|ERR|"

    // Stashed request body (set by buildRequestData, embedded by finalizeScriptContent)
    property string requestDataJSON: "{}"

    // File that persists the opencode session id across requests
    property string sessionFile: "/tmp/quickshell/ai/opencode-session.txt"

    function buildEndpoint(model: AiModel): string {
        return root.serverBase;
    }

    function buildRequestData(model: AiModel, messages, systemPrompt: string, temperature: real, tools: list<var>, filePath: string) {
        // Only the newest user turn is sent; history lives in the reused session.
        let text = "";
        for (let i = messages.length - 1; i >= 0; i--) {
            const m = messages[i];
            if (m.role === "user" && m.rawContent && m.rawContent.length > 0) {
                text = m.rawContent;
                break;
            }
        }
        const body = { "parts": [ { "type": "text", "text": text } ] };
        root.requestDataJSON = JSON.stringify(body);
        return body;
    }

    function buildAuthorizationHeader(apiKeyEnvVarName: string): string {
        // opencode manages its own credentials; no auth header needed.
        return "";
    }

    function parseResponseLine(line, message) {
        if (line.startsWith(root.textPrefix)) {
            const decoded = root.decodeJsonText(line.slice(root.textPrefix.length));
            if (root.isThinking) {
                root.isThinking = false;
                const endBlock = "\n\n response\n\n";
                message.rawContent += endBlock;
                message.content += endBlock;
            }
            message.rawContent += decoded;
            message.content += decoded;
        } else if (line.startsWith(root.thinkPrefix)) {
            const decoded = root.decodeJsonText(line.slice(root.thinkPrefix.length));
            if (!root.isThinking) {
                root.isThinking = true;
                const startBlock = "\n\n thinking\n\n";
                message.rawContent += startBlock;
                message.content += startBlock;
            }
            message.rawContent += decoded;
            message.content += decoded;
        } else if (line.startsWith(root.donePrefix)) {
            root.isThinking = false;
            let tokens = {};
            try {
                tokens = JSON.parse(line.slice(root.donePrefix.length));
            } catch (e) { /* ignore */ }
            return {
                tokenUsage: {
                    input: tokens.input ?? -1,
                    output: tokens.output ?? -1,
                    total: tokens.total ?? -1,
                },
                finished: true
            };
        } else if (line.startsWith(root.errPrefix)) {
            const decoded = root.decodeJsonText(line.slice(root.errPrefix.length));
            message.rawContent += decoded;
            message.content += decoded;
            return { finished: true };
        }
        // Ignore other lines (server startup messages etc.)
        return {};
    }

    function onRequestFinished(message) {
        return {};
    }

    function reset() {
        root.isThinking = false;
    }

    function buildScriptFileSetup(filePath) {
        return "";
    }

    function finalizeScriptContent(scriptContent: string): string {
        // Ignore the generic curl content; build our own polling script.
        const shebang = "#!/usr/bin/env bash\n";
        return shebang + root.buildPollScript();
    }

    function decodeJsonText(encoded: string): string {
        try {
            return JSON.parse(encoded);
        } catch (e) {
            return encoded;
        }
    }

    function buildPollScript(): string {
        const base = root.serverBase;
        const sessFile = root.sessionFile;
        const body = CF.StringUtils.shellSingleQuoteEscape(root.requestDataJSON);
        let c = "";
        c += `BASE='${base}'\n`;
        c += `SESSFILE='${sessFile}'\n`;
        c += `BODY='${body}'\n`;
        // Start the opencode server if it is not already running.
        c += 'HW=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/global/health")\n';
        c += 'if [ "$HW" != "200" ]; then\n';
        c += '  mkdir -p "$(dirname "$SESSFILE")" 2>/dev/null\n';
        c += '  nohup opencode serve --port 4100 >>/tmp/quickshell/ai/opencode-server.log 2>&1 &\n';
        c += '  N=0\n';
        c += '  while [ "$N" -lt 60 ]; do\n';
        c += '    [ "$(curl -s -o /dev/null -w "%{http_code}" "$BASE/global/health" 2>/dev/null)" = "200" ] && break\n';
        c += '    sleep 0.5; N=$((N+1))\n';
        c += '  done\n';
        c += 'fi\n';
        c += 'HW=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/global/health" 2>/dev/null)\n';
        c += 'if [ "$HW" != "200" ]; then\n';
        c += '  echo "OC|ERR|"$(printf %s "opencode server could not be started" | jq -Rs .)\n';
        c += '  exit 1\n';
        c += 'fi\n';
        // Reuse existing session or create a new one.
        c += 'SID=""\n';
        c += 'if [ -f "$SESSFILE" ]; then SID=$(cat "$SESSFILE"); fi\n';
        c += 'if [ -n "$SID" ]; then\n';
        c += '  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/session/$SID")\n';
        c += '  [ "$CODE" != "200" ] && SID=""\n';
        c += 'fi\n';
        c += 'if [ -z "$SID" ]; then\n';
        c += '  SID=$(curl -s -X POST "$BASE/session" -H "Content-Type: application/json" -d \'{"title":"II Chat"}\' | jq -r ".id")\n';
        c += '  echo "$SID" > "$SESSFILE"\n';
        c += 'fi\n';
        c += 'if [ -z "$SID" ] || [ "$SID" = "null" ]; then\n';
        c += '  echo "OC|ERR|"$(printf %s "opencode server unreachable" | jq -Rs .)\n';
        c += '  exit 1\n';
        c += 'fi\n';
        c += 'curl -s -X POST "$BASE/session/$SID/prompt_async" -H "Content-Type: application/json" -d "$BODY" > /dev/null\n';
        c += 'i=0\n';
        c += 'while :; do\n';
        c += '  MSG=$(curl -s "$BASE/session/$SID/message?limit=1")\n';
        c += '  [ -z "$MSG" ] && { sleep 0.4; continue; }\n';
        c += '  FINISH=$(echo "$MSG" | jq -r ".[0].info.finish // empty")\n';
        c += '  CNT=$(echo "$MSG" | jq "[.[0].parts[] | select(.type==\\"text\\" or .type==\\"reasoning\\")] | length" 2>/dev/null)\n';
        c += '  case "$CNT" in ""|null) CNT=0 ;; esac\n';
        c += '  while [ "$i" -lt "$CNT" ]; do\n';
        c += '    P=$(echo "$MSG" | jq -c "[.[0].parts[] | select(.type==\\"text\\" or .type==\\"reasoning\\")][$i]")\n';
        c += '    T=$(echo "$P" | jq -r ".type")\n';
        c += '    TXT=$(echo "$P" | jq -r ".text // \\"\\"")\n';
        c += '    if [ "$T" = "text" ]; then\n';
        c += '      echo "OC|TEXT|"$(printf %s "$TXT" | jq -Rs .)\n';
        c += '    else\n';
        c += '      echo "OC|THINK|"$(printf %s "$TXT" | jq -Rs .)\n';
        c += '    fi\n';
        c += '    i=$((i+1))\n';
        c += '  done\n';
        c += '  if [ -n "$FINISH" ]; then\n';
        c += '    TOK=$(echo "$MSG" | jq -c ".[0].info.tokens // {}")\n';
        c += '    case "$TOK" in null) TOK="{}" ;; esac\n';
        c += '    echo "OC|DONE|"$TOK\n';
        c += '    break\n';
        c += '  fi\n';
        c += '  sleep 0.4\n';
        c += 'done\n';
        return c;
    }
}
