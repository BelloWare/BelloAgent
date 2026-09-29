# Background requests

The app asks a connection's mini model for three things on its own:

- **Chat titles.** A new chat's title is written from its first message.
- **Title suggestions.** The Rename sheet asks for three titles.
- **Webhook notifications.** A webhook's parameters are written when a chat
  finishes or its preview is opened (Settings → Chats & notifications).

Each runs in a chat of its own outside every project, with its own journal,
captured requests and billing. The Background requests page lists them all.
They are never shown in the sidebar. The page replaced the sidebar's eye
toggle ("Show background tasks in the list"), which mixed them into the chat
list.

The code:

- `apps/macos/PiApp/Workspaces/BackgroundRequests.swift` holds the records,
  statuses, rows and the page's state (`BackgroundRequestsController`).
- `apps/macos/PiApp/Dashboard/BackgroundRequestsPage.swift` holds the page.

## Opening it

- The sidebar footer's button with the stacked-sparkles symbol, beside
  Usage Report. It turns into Back to Chats while the page is open.
- View → Background Requests (⇧⌘B).
- Selecting a background request from anywhere else: the menu bar's running
  requests, or a Usage Report row. The page opens with that request selected.

The page covers the chats as the Usage Report does. The chat underneath keeps
its draft, scroll and any run. Esc or Chats goes back. A relaunch comes back
on the page if it was open.

## The list

Requests are listed newest first. The filter shows All, Chat titles, Title
suggestions or Webhooks. The header counts the requests shown, how many are
running and how many failed, with their reported tokens and cost.

Each row shows two lines:

1. The kind and what the request produced: the title, the three suggestions,
   or the notification's parameters (`name: value`). Then how long it took,
   and its status:
   - **Running**, with a spinner;
   - **Done**;
   - **Failed**, with the reason in place of a result;
   - **Interrupted**: stopped by its reader (the Rename sheet or the webhook
     preview closed first), or cut short when the app quit or crashed.
2. When it was sent (exact time on hover). Then the chat it was for, which
   opens that chat on click, and the chat's project, the connection and the
   model. At the right, the tokens and cost the gateway reported, read from
   the request archive as the sidebar's figures are.

On a narrow row, the connection, then the project, then the model are left
out whole, rather than squeezed.

## A request's details

Selecting a row shows:

- the request's status and result;
- the full failure or interruption reason;
- the chat, project, connection, model, end time, duration, tokens, cost and
  number of requests;
- the prompt sent and the full reply, read from the request's journal off the
  main thread.

It offers two actions:

- **Open Source Chat** goes back to the chat the request was for.
- **Inspect Requests** opens the request's Session Inspector: its captured
  bodies, usage and timing.

A wide page shows the details beside the list. A narrow one shows them in
the list's place, and closing them returns to the list where it was.

## What is kept

A request's chat record keeps:

- `backgroundTaskStartedAt` and `backgroundTaskEndedAt`;
- `backgroundTaskOutcome`: completed, failed or interrupted, or none while
  it runs;
- `backgroundTaskResult`;
- the existing `backgroundTaskNotice`, which holds the reason for a failure
  or interruption.

Nothing is deleted when a request ends. Title suggestions and webhook
requests used to be removed as soon as they answered, and launch removed any
a quit had left.

Launch settles what the last run left (`settleBackgroundRequests`):

- A request that never recorded its end reads "Interrupted when Bello Agent
  closed." Nothing is sent again.
- A chat title interrupted that way is still asked again once, with the
  chat's next message, as before.
- Records written before these fields existed get their outcome from what
  they left: their notice, or, for a chat title, whether the chat took a
  title from it. The first time the page opens, their results are read from
  their journals once and kept.

Nothing caps how many requests are kept: every one is listed, and each keeps
its journal and captured requests. Each is small: a record, a journal of a
few kilobytes, and its capture, which the request archive's own retention
already governs.

## Performance

- The rows are built from the records when the records change, never while
  the page is drawn.
- The list is lazy.
- The per-session accounting is one grouped read of the request archive.
- A selected request's journal is read on its own history reader, off the
  main thread, so the chats' page indexes are untouched.
