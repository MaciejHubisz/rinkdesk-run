# RinkDesk manuals. Sourced by ./start.sh.

print_usage() {
  cat <<EOF
${BOLD}${ICE}RinkDesk${RESET} ${APP_VERSION}  rink-clerk desk for ice and roller hockey

  ${GREEN}./start.sh${RESET}                     this list
  ${GREEN}./start.sh --start${RESET}             start or resume, keep Postgres data
  ${GREEN}./start.sh --force-recreate${RESET}    wipe Postgres, pull images, start empty
  ${GREEN}./start.sh --stop${RESET}              stop frontend, backend, and database (data kept)
  ${GREEN}./start.sh --setup${RESET}             tab completion on this machine (yes/no)
  ${GREEN}./start.sh --manual${RESET}            data manual (roles, screens, workflow)

  ${GREEN}-p, --port PORT${RESET}                host port for the UI (default ${PORT})
  ${GREEN}-n, --no-open${RESET}                  do not open a browser
  ${GREEN}-V, --version${RESET}                  print version and git commit
  ${GREEN}-h, --help${RESET}                     this list

  Windows:  ${GREEN}.\\start.ps1${RESET}  (same flags, via WSL)
  Engine:   docker if a daemon answers, else Podman.
  Images:   pulled from the registry in ${DIM}.env${RESET} — this folder has no source code.
EOF
}

print_manual() {
  cat <<EOF
${BOLD}${ICE}RinkDesk data manual${RESET}  ${APP_VERSION} ($(git_commit))
Amateur tournament desk · ice 5-on-5 · summer roller 4-on-4
Commands:  ${GREEN}./start.sh${RESET}

$(hr)
${BOLD}1. Sign in${RESET}

  Roles — and only these:

    ${BOLD}admin${RESET}  clerk. Licenses, teams, schedule, everything.
            Creating a team creates its only login (username = short name).
    ${BOLD}ref${RESET}    referee. Approve lineups, enter protocol, confirm.
            Cannot register people, create teams, or schedule matches.
    ${BOLD}team${RESET}   one account per club. Own roster and own lineup only.
            Cannot approve, cannot enter protocol, cannot schedule.

  Built-in clerk logins (change them in Settings):

    admin / admin     ref / ref

  Importing a snapshot also restores one login per club (short name).

  Change them under Settings. Session survives a refresh; Sign out clears it.
  The API rejects illegal calls even if the UI is bypassed.

  Language: Polish is the default. Switch PL / EN on the login card,
  in the top bar, and under Settings. Every form, table, toast, and
  confirm follows that choice.

$(hr)
${BOLD}2. What this is${RESET}

  A rink clerk’s book: licenses, teams, match lineups, protocols,
  standings. Not a live scoreboard.

  Data lives on the server, not in the browser.
  Frontend, API, and Postgres are three Compose services (images only).
  Settings → Export writes a timestamped copy inside the app volume
  (not as files in this folder). Settings → Import lets you pick the
  newest export or the factory default snapshot that ships in the image.

$(hr)
${BOLD}3. Screens${RESET}

  ${BOLD}Desk${RESET}        today’s matches and the next required action
  ${BOLD}Licenses${RESET}    master register — a person is entered once
  ${BOLD}Teams${RESET}       club cards + kit swatches; open a team to assign
  ${BOLD}Matches${RESET}     schedule, then open the match desk
  ${BOLD}Standings${RESET}   season table, goal leaders, assists, penalties
  ${BOLD}Settings${RESET}    tournament name, JSON export/import

$(hr)
${BOLD}4. Official workflow — no skips${RESET}

  ${GOLD}scheduled → lineup submitted → BOTH lineups approved → protocol confirmed${RESET}

    1. Register licenses (active only can be assigned or dressed).
    2. Create teams. Assign from the license list.
       Jersey unique on that team. One C, max two A.
       A license cannot sit on two teams.
    3. Schedule a match. Home ≠ away. Each team must already have
       enough assigned players for that discipline.
    4. Match desk → pick players → ${BOLD}Save draft${RESET} → ${BOLD}Submit${RESET}.
    5. ${BOLD}Approve${RESET} both sides. Protocol stays locked until then.
    6. Enter goals and penalties. Score is the goal count — there is
       no manual score field.
    7. ${BOLD}Confirm protocol${RESET}. Only then does it hit the table.

  Undo is one confirmed step:
    unsubmit a submitted lineup · unapprove if protocol not confirmed
    · unconfirm a protocol (it drops out of standings).

  If a button is illegal it is disabled, with one sentence why.

$(hr)
${BOLD}5. Ice vs roller${RESET}

  Tournament default discipline is in Settings. A match can override it.
  Override changes ${BOLD}lineup limits and the period list only${RESET}.

                    ${BOLD}Ice 5-on-5${RESET}                 ${BOLD}Roller 4-on-4${RESET}
  On surface        1 G + 5 skaters             1 G + 3 skaters
  Club roster max   20 skaters + 2 G            10 total
  Lineup            min 6 (incl. 1 G)           min 4 (incl. 1 G)
                    max 20 skaters + 2 G        max 8, at most 2 G
  Periods           1 2 3 OT SO                 1 2 3 4 OT SO

$(hr)
${BOLD}6. Licenses, teams, protocol${RESET}

  ${BOLD}License${RESET}   number unique, first, last, optional birth year,
            default # 1–99, position G/D/F, status active|suspended.
            Search by name or number. Do not delete an assigned license
            or one on an approved lineup — suspend instead.

  ${BOLD}Team${RESET}      name, short, city, home kit, away kit, optional accent.
            Cannot delete a team that has matches.

  ${BOLD}Goal${RESET}      period, mm:ss, team, scorer, A1, A2, type EQ/PP/SH/EN/PS
  ${BOLD}Penalty${RESET}   period, mm:ss, team, player,
            minutes 2 / 2+2 / 4 / 5 / 10 / 20 / 25,
            type HOOK TRIP HOLD SLASH ROUGH BOARD TOO-MANY FIGHT MISC GAME
  Scorer and penalized player must be on that side’s approved lineup.
  Cannot confirm a tie. Set OT or SO and add the deciding goal.
  Decision: regulation | overtime | shootout.
  Print sheet: browser print on a confirmed match. Priority export is JSON.

$(hr)
${BOLD}7. Standings${RESET}

  Pick a season, then switch views: table · goal leaders · assists · penalties.
  3 pts regulation win · 2 OT/SO win · 1 OT/SO loss · 0 regulation loss
  Table: # Team GP W OTW OTL L GF:GA +/− PIM GM Pts
  Goals: G plus EQ/PP/SH/EN/PS, GWG, first goal of the match
  Assists: A1, A2, A (= A1+A2), G, Pts
  Penalties: PIM plus 2 / 2+2 / 5 / 10 / match penalty / GM
  Sort table: points, goal difference, goals for, name.

$(hr)
${BOLD}8. Snapshot export / import${RESET}

  ${BOLD}Export${RESET}   writes a timestamped copy on the server (no browser download)
  ${BOLD}Import${RESET}   pick the newest export or the factory default snapshot
  ${BOLD}Protocols JSON${RESET}   confirmed match sheets (browser download)

  ${GREEN}./start.sh --start${RESET} keeps current Postgres data.
  ${GREEN}./start.sh --force-recreate${RESET} wipes the database and starts empty.
  Clearing the browser does not wipe the desk.
  Dumps stay inside Docker volumes, not in this cloned folder.

$(hr)
${BOLD}9. Refusals (the API will reject these)${RESET}

  duplicate license number · duplicate jersey on one team
  player outside the license list · suspended license in a lineup
  protocol before both approvals · points before confirm
  a team playing itself
  ice limits on a roller match, or roller limits on an ice match

$(hr)
${DIM}RinkDesk ${APP_VERSION}  ·  run with ./start.sh --start${RESET}
EOF
}
