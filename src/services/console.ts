import { invoke } from "@tauri-apps/api/core";
import type { OpencodeStatus } from "./opencode";

export interface ConsoleOrg {
  accountID: string;
  accountEmail: string;
  accountUrl: string;
  orgID: string;
  orgName: string;
  active: boolean;
}

export interface ConsoleState {
  consoleManagedProviders: string[];
  activeOrgName?: string;
  switchableOrgCount: number;
}

export const consoleService = {
  state: () => invoke<ConsoleState>("console_state"),
  orgs: () => invoke<ConsoleOrg[]>("console_orgs"),
  /** Switches active console org and restarts opencode serve to apply it. */
  switch: (accountID: string, orgID: string) =>
    invoke<OpencodeStatus>("console_switch", { accountId: accountID, orgId: orgID }),
  /** Opens a terminal running `opencode console login` (device-code flow). */
  login: () => invoke<string>("console_login"),
  logout: (email: string) => invoke<string>("console_logout", { email }),
};
