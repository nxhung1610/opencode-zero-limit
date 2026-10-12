import { invokeCommand } from "./bridge";
import type { OpencodeStatus } from "./opencode";

export interface ConsoleConnection {
  id: string;
  label: string;
  active: boolean;
  method: "oauth";
}

export interface ConsoleLoginAttempt {
  attemptID: string;
  url: string;
  instructions: string;
  mode: "auto" | "code";
}

export type ConsoleLoginStatus =
  | { status: "pending" }
  | { status: "complete" }
  | { status: "failed" | "expired"; message: string };

export const consoleService = {
  connections: () => invokeCommand<ConsoleConnection[]>("console_connections"),
  loginStart: () => invokeCommand<ConsoleLoginAttempt>("console_login_start"),
  loginStatus: (attemptID: string) => invokeCommand<ConsoleLoginStatus>("console_login_status", { attemptID }),
  loginComplete: (attemptID: string, code: string) =>
    invokeCommand<void>("console_login_complete", { attemptID, code }),
  loginCancel: (attemptID: string) => invokeCommand<void>("console_login_cancel", { attemptID }),
  activate: (credentialID: string) => invokeCommand<OpencodeStatus>("console_activate", { credentialID }),
  logout: (credentialID: string) => invokeCommand<string>("console_logout", { credentialID }),
};
