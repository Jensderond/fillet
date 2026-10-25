import FilletAgent
import SwiftUI

/// Over the viewport while an agent designs in this window: "Claude is designing · Fillet · Hat brim".
struct AgentPill: View {
    let agent: String
    let activity: String?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "sparkles")
                .symbolEffect(.pulse, options: .repeating, isActive: activity != nil)
                .foregroundStyle(Theme.fillet)
            Text("\(agent) is designing").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.raised)
            if let activity {
                Text(activity).font(Theme.body).foregroundStyle(Theme.raised.opacity(0.75)).lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Capsule().fill(Theme.ink.opacity(0.88)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Toolbar button: whether agents may connect, and how to connect one.
struct AgentToolbarButton: View {
    @State private var showing = false
    private var hub: AgentHub { AgentHub.shared }

    var body: some View {
        Button { showing.toggle() } label: {
            Label("Agents", systemImage: hub.isEnabled ? "sparkles" : "sparkle")
        }
        .help(hub.isEnabled ? "Agents can design here — \(hub.statusText)" : "Let AI agents design in Fillet")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            AgentSettings()
                .frame(width: 380)
                .padding(Theme.Space.l)
        }
    }
}

/// Allow agents, and the details an agent needs to connect.
struct AgentSettings: View {
    @Bindable private var hub = AgentHub.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Toggle(isOn: $hub.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow agent connections").font(Theme.body.weight(.semibold))
                    Text("AI agents (Claude Code and other MCP clients) can build in the open design while you watch. Every step can be undone.")
                        .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if hub.isEnabled {
                Label(hub.statusText, systemImage: hub.isListening ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(hub.isListening ? Theme.ok : Theme.warn)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Connect Claude Code").font(Theme.caption.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
                    Text(hub.claudeCodeCommand)
                        .font(Theme.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(Theme.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.panel))
                    Button(copied ? "Copied" : "Copy command") {
                        copy(hub.claudeCodeCommand)
                        copied = true
                    }
                    #if os(iOS)
                    Text("Run it on a Mac on the same network. Other devices need the token in the command.")
                        .font(Theme.caption).foregroundStyle(Theme.inkSecondary)
                    #endif
                }
            }
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension AgentHub {
    var isListening: Bool { if case .listening = state { true } else { false } }

    var statusText: String {
        switch state {
        case .stopped: "Off"
        case .starting: "Starting…"
        case .listening: clientName != nil ? "\(agentName) connected at \(endpoint)" : "Waiting for agents at \(endpoint)"
        case .failed(let reason): "Can't listen on port \(port): \(reason)"
        }
    }
}
