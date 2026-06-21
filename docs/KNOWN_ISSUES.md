# Known Issues

## Phase 3 — Group membership sync (open)

Group chats work, but membership changes don't propagate to other participants'
apps. All four symptoms below share the same root: group membership lives
server-side, but each client fans messages out to the member list **it last
fetched locally**, and clients are never notified when membership changes. There
is no mechanism (control message, push, or server-side group fan-out) to keep
every participant's local member list in sync.

1. **New group not shown to other participants on creation.**
   When a group is created it only appears in the creator's app. Other members
   don't see the group until (currently) they restart / re-login and `loadGroups`
   runs. New members should see the group appear live.

2. **Removal is not consistent across participants.**
   Removing a member updates the remover's view only. Other participants still
   show the removed user as a member, and still deliver messages to them.

3. **Removed user can still send to the chat.**
   A removed user's app keeps its stale member list, so it can still fan messages
   out to everyone. (Note: even with client sync, the server does not currently
   enforce membership on message relay — messages are plain 1:1 relays — so
   server-side authorization would also be needed to truly cut off a removed
   member.)

4. **Added-after-creation member only receives the adder's messages.**
   When a member is added later, only the person who added them has the updated
   member list, so only their messages reach the new member. Other participants
   (with stale lists) don't send to the newly added user.

5. **Group chats reappear empty after logout/login.**
   Logout clears local state, but on next login `loadGroups` repopulates groups
   from the server (group membership is persisted server-side) while message
   history is in-memory only and was wiped. Result: the group chats show up in
   the list again with no messages. Either persist/clear group state to match the
   "logout deletes chats" expectation, or persist message history locally so it
   survives re-login.

### Direction (not yet implemented)
- Propagate membership changes to all members (e.g. a group "membership-updated"
  control message fanned out to current members, prompting each client to
  re-fetch the group), or move group fan-out server-side.
- Enforce group membership on the server for any group-addressed relay so a
  removed member cannot send/receive regardless of client state.
