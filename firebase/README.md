# Brisko Billing — Cloud backend (Firebase)

This directory is the entire cloud-side setup for Brisko Billing's sync and backup
layer. It is **not** applied automatically and points at **your own** Firebase
project; each outlet uses its own project or its own restaurant account.

## Why Firebase

The wider Brisko ecosystem — and the future customer-facing Android app — already runs
on Firebase, so the point-of-sale terminal joins the same cloud rather than standing up a
second auth-and-database stack. The terminal reaches **Firebase Realtime Database** and
**Firebase Authentication** over their HTTPS APIs through a thin `dart:io` client, so the
desktop build needs no native plugins and no CocoaPods, the dependency list stays
minimal, and the whole sync path can be tested without a live project. The data and the
security rules are identical to what a native-SDK client would see, so an Android app
built on FlutterFire shares the same RTDB and the same accounts.

## Data structure

One node per entity, one tree per restaurant, keyed by the stable device-generated id:

```
restaurants/{restaurantId}/categories/{id}
restaurants/{restaurantId}/menuItems/{id}
restaurants/{restaurantId}/menuItemVariants/{id}
restaurants/{restaurantId}/menuItemOptions/{id}
restaurants/{restaurantId}/inventoryItems/{id}
restaurants/{restaurantId}/recipeIngredients/{id}
restaurants/{restaurantId}/stockMovements/{id}
restaurants/{restaurantId}/customers/{id}
restaurants/{restaurantId}/orders/{id}
restaurants/{restaurantId}/orderItems/{id}
restaurants/{restaurantId}/orderItemOptions/{id}
restaurants/{restaurantId}/payments/{id}
restaurants/{restaurantId}/refunds/{id}
restaurants/{restaurantId}/orderInventoryDeductions/{id}
restaurants/{restaurantId}/kotRecords/{id}
restaurants/{restaurantId}/kotItems/{id}
restaurants/{restaurantId}/kotItemOptions/{id}
restaurants/{restaurantId}/expenses/{id}
restaurants/{restaurantId}/managerPassword
```

`restaurantId` is the signed-in Firebase user's `uid`: a restaurant **is** a Firebase
Authentication user. Each node stores the entity exactly as the local SQLite row
does — same camelCase fields, millisecond `updatedAt`, `isDeleted` flag — so
last-write-wins falls out of comparing `updatedAt` and a soft delete is a node with
its flag set. The `id` field is also the node key, which is what makes a replay or a
restore update in place instead of creating a duplicate.

Realtime Database URL for this project:

```
https://brisko-billing-default-rtdb.asia-southeast1.firebasedatabase.app/
```

## Setup

1. Create a Firebase project (or reuse the Brisko project).
2. Enable **Realtime Database** and **Email/Password** sign-in under Authentication.
3. Deploy `database.rules.json` (Firebase console → Realtime Database → Rules, or
   `firebase deploy --only database`).
4. Create a user for the terminal (Authentication → Users). That user's `uid` is the
   restaurant id and the root of its node tree. This email and password are what the
   restaurant signs in with on the terminal's login screen.
5. Build the app with the project's **client-safe** values (the project id and the Web
   API key) as compile-time configuration. They are application configuration, the same
   for every terminal of the build, not per-restaurant settings:

   ```
   flutter build macos --debug \
     --dart-define=BRISKO_FIREBASE_PROJECT_ID=brisko-billing \
     --dart-define=BRISKO_FIREBASE_API_KEY=AIza...
   ```

   Built without them, the app runs **fully local**: no login screen, every change saved
   to SQLite and queued, exactly the offline-first behaviour.

6. On first launch of a cloud build, the terminal shows a **login screen**. The restaurant
   signs in with the email and password from step 4. The app exchanges them for a session
   (a refresh token), persists that session locally so the next launch skips the login
   screen, and from then on syncs in the background. The **password is never stored**, and
   there is no screen for entering API keys, project ids, refresh tokens or service
   credentials — those are build configuration or session state, not user input.

## Security

- The app holds only **client-safe** values: the project id and Web API key (build
  configuration), and a signed-in user's refresh token (a session, refreshed into
  short-lived ID tokens and persisted locally). It never holds the service-account key or
  any password — the password is exchanged for a session at sign-in and then discarded.
- Access is controlled by **Realtime Database Security Rules** (`database.rules.json`),
  not by secrecy of the API key. The key alone can read and write nothing; a valid user
  session is required, and that session can only reach its own restaurant's nodes.
- The rules enforce that one authenticated restaurant cannot read or write another
  restaurant's data. This is server-side and cannot be bypassed by the client.

## Sync semantics (for reference)

- **Push** replays the local outbox oldest-first as RTDB PATCH writes keyed on
  the stable node id, so a replay or a restore can never duplicate a node.
- **Pull** GETs each collection node, filters to `updatedAt > cursor`, orders by
  `updatedAt` ascending, and merges last-write-wins, refusing to overwrite a newer
  local record.
- The cloud does **not** enforce cross-node relationships. The single writing
  terminal is the source of referential integrity, which means a queued write never fails
  on ordering.
