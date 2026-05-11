import Foundation

/// App Store Connect endpoints covering the general-purpose Webhooks
/// API (introduced in OpenAPI spec v4.0, June 2025). Webhooks let a
/// developer subscribe an HTTPS endpoint to App Store Connect event
/// types (build status changes, review state transitions, app
/// availability changes, TestFlight events, etc.) so a reactive AI
/// agent (or any other automation) can drive workflows off live ASC
/// state without polling.
///
/// This is the *general-purpose* webhooks resource. It is distinct
/// from `marketplaceWebhooks` (EU DMA Alternative Distribution only),
/// which is wrapped separately in `AltDistributionAPI.marketplaceWebhooks`.
/// Use `webhooks` here for everything that is not marketplace-
/// distribution-specific.
///
/// Resources wrapped here, with the JSON:API types Apple documents:
///
///   - webhooks: the subscription itself. Holds the target `url`,
///     friendly `name`, a list of subscribed `eventTypes`, an
///     HMAC `secret` Apple signs each payload with, an `active`
///     toggle, and an `app` relationship that scopes the
///     subscription to one app. CRUD.
///   - webhookDeliveries: read-only history of every payload Apple
///     sent for a webhook. Includes `eventType`, `state`,
///     `attemptCount`, `responseCode`, `responseBody`, and the
///     stored `payload`. Resends are POSTed against the parent
///     deliveries collection.
///   - webhookPings: write-only collection used to dispatch a
///     synthetic ping payload to a webhook URL to confirm the
///     endpoint is reachable and properly verifying signatures.
///
/// Plus one relationship endpoint on the apps resource:
///   - apps/{id}/webhooks: list webhooks scoped to a specific app.
///     Useful when the agent already has the app id and only wants
///     the subscriptions hanging off that app.
///
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi
/// (Webhooks section)
///
/// Pagination convention: every list endpoint accepts an optional
/// `limit` and `cursor` and returns `(data, nextCursor)`. The cursor
/// is Apple's opaque `links.next` continuation token; pass it back
/// unchanged on the next call. When `nextCursor` is nil, the caller
/// has reached the end of the list.
///
/// Master struct + nested namespaces pattern (mirrors TestFlightAPI
/// and AltDistributionAPI):
///
///   let api = WebhooksAPI(client: client)
///   try await api.webhooks.list(limit: 50)
///   try await api.deliveries.list(webhookID: "wh-1")
///   try await api.pings.create(webhookID: "wh-1")
///
package struct WebhooksAPI {
    package let client: ASCClient

    package init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Nested namespaces

    /// Webhook subscriptions. CRUD + per-app scoped list.
    package var webhooks: Webhooks { Webhooks(client: client) }
    /// Read-only delivery history per webhook, with resend.
    package var deliveries: Deliveries { Deliveries(client: client) }
    /// Synthetic ping deliveries for endpoint health checks.
    package var pings: Pings { Pings(client: client) }

    // MARK: - Shared paged response shape

    /// Generic JSON:API page envelope. Apple returns `links.next` as
    /// a full URL with a base64-encoded `cursor=` query parameter; we
    /// extract the cursor value so callers can pass it back on
    /// subsequent calls without parsing the URL themselves.
    package struct Page<Item: Codable & Sendable>: Sendable {
        package let data: [Item]
        package let nextCursor: String?
    }

    /// Internal helper: decodes a JSON:API list response and pulls
    /// out the `cursor=` parameter from `links.next` if present.
    fileprivate struct PageEnvelope<Item: Codable>: Decodable {
        struct Links: Decodable { let next: String? }
        let data: [Item]
        let links: Links?
    }

    fileprivate static func extractCursor(from link: String?) -> String? {
        guard let link, !link.isEmpty,
              let comps = URLComponents(string: link)
        else { return nil }
        return comps.queryItems?.first(where: { $0.name == "cursor" })?.value
    }

    /// Standard list query builder used by every paged endpoint here.
    fileprivate static func listQuery(
        limit: Int,
        cursor: String?,
        extras: [String: String] = [:]
    ) -> [String: String] {
        var q = extras
        q["limit"] = String(limit)
        if let cursor, !cursor.isEmpty { q["cursor"] = cursor }
        return q
    }

    // MARK: - webhooks

    /// A webhook subscription. Apple POSTs JSON payloads to `url`
    /// every time one of the subscribed `eventTypes` fires for the
    /// owning app. Each payload is signed with `secret` using HMAC
    /// so the receiving endpoint can verify authenticity.
    ///
    /// `eventTypes` is modeled as `[String]` rather than a Swift
    /// enum: Apple ships new event types every quarter (build
    /// status, review state, app availability, in-app purchases,
    /// subscriptions, TestFlight, etc.) and pinning a fixed enum
    /// here would force a CLI release every time Apple extends the
    /// catalog. Callers should treat the field as opaque-but-string
    /// and consult Apple's docs for the current set.
    package struct Webhook: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package let relationships: Relationships?

        package struct Attributes: Codable, Sendable {
            /// HTTPS endpoint Apple POSTs event payloads to.
            package let url: String?
            /// Human-friendly label shown in the ASC web UI. Doesn't
            /// affect routing; just helps the developer keep
            /// multiple subscriptions straight.
            package let name: String?
            /// List of event-type identifiers this subscription is
            /// listening for. Pass-through `[String]` so we can ship
            /// new Apple-side event types without a code release.
            package let eventTypes: [String]?
            /// HMAC shared secret Apple signs each payload with. On
            /// reads, Apple typically redacts this and returns nil
            /// (the value only round-trips once at create time, so
            /// the developer should store it locally then).
            package let secret: String?
            /// When false, Apple stops dispatching deliveries to the
            /// `url` but keeps the record around for later
            /// reactivation. Use this for soft-disable instead of
            /// deleting + recreating.
            package let active: Bool?
        }

        /// Relationship envelope. Apple ships the linked-app id under
        /// `relationships.app.data.id`. We expose it here so callers
        /// can find the owning app without a follow-up GET.
        package struct Relationships: Codable, Sendable {
            package let app: AppRel?

            package struct AppRel: Codable, Sendable {
                package let data: Ref?
                package struct Ref: Codable, Sendable {
                    package let id: String
                    package let type: String
                }
            }
        }
    }

    /// Fields accepted on a webhook PATCH. Nil fields are omitted
    /// from the wire body so existing values stay untouched on the
    /// server.
    package struct WebhookUpdateFields: Sendable, Equatable {
        package var url: String?
        package var name: String?
        package var eventTypes: [String]?
        package var secret: String?
        package var active: Bool?

        package init(
            url: String? = nil,
            name: String? = nil,
            eventTypes: [String]? = nil,
            secret: String? = nil,
            active: Bool? = nil
        ) {
            self.url = url
            self.name = name
            self.eventTypes = eventTypes
            self.secret = secret
            self.active = active
        }
    }

    /// Webhooks namespace: CRUD plus the per-app scoped list helper.
    package struct Webhooks {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        /// Lists every webhook on the account. Use `listForApp` when
        /// the caller has an app id and only wants its subscriptions.
        package func list(
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Webhook> {
            let resp: PageEnvelope<Webhook> = try await client.get(
                path: "webhooks",
                query: WebhooksAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Webhook>.self
            )
            return .init(
                data: resp.data,
                nextCursor: WebhooksAPI.extractCursor(from: resp.links?.next)
            )
        }

        /// Lists webhooks scoped to a specific app. Wraps the
        /// `apps/{id}/webhooks` relationship endpoint.
        package func listForApp(
            appID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Webhook> {
            let resp: PageEnvelope<Webhook> = try await client.get(
                path: "apps/\(appID)/webhooks",
                query: WebhooksAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Webhook>.self
            )
            return .init(
                data: resp.data,
                nextCursor: WebhooksAPI.extractCursor(from: resp.links?.next)
            )
        }

        /// Fetches a single webhook by id. Returns nil on 404.
        package func get(id: String) async throws -> Webhook? {
            struct Resp: Decodable { let data: Webhook }
            do {
                let resp: Resp = try await client.get(
                    path: "webhooks/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Creates a webhook subscription on `appID`. Apple will
        /// start dispatching POSTs to `url` for each event listed in
        /// `eventTypes` once the record is created (assuming
        /// `active` is true, which is the server-side default).
        ///
        /// Apple returns the `secret` value on the create response,
        /// so capture it from the resulting `Webhook` if the caller
        /// needs to verify signatures on incoming payloads. On
        /// subsequent reads, Apple typically redacts the secret.
        @discardableResult
        package func create(
            appID: String,
            url: String,
            name: String,
            eventTypes: [String],
            secret: String? = nil,
            active: Bool? = nil
        ) async throws -> Webhook {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "webhooks"
                    let attributes: Attrs
                    let relationships: Rels
                }
                struct Attrs: Encodable {
                    let url: String
                    let name: String
                    let eventTypes: [String]
                    var secret: String?
                    var active: Bool?
                }
                struct Rels: Encodable {
                    struct App: Encodable {
                        struct D: Encodable { let type = "apps"; let id: String }
                        let data: D
                    }
                    let app: App
                }
                let data: Data
            }
            let body = Body(data: .init(
                attributes: .init(
                    url: url,
                    name: name,
                    eventTypes: eventTypes,
                    secret: secret,
                    active: active
                ),
                relationships: .init(app: .init(data: .init(id: appID)))
            ))
            struct Resp: Decodable { let data: Webhook }
            let resp: Resp = try await client.post(
                path: "webhooks",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        /// PATCH any non-nil fields on an existing webhook. Nil
        /// fields are omitted from the wire body so values you don't
        /// pass stay untouched. The owning app cannot be reassigned
        /// after create.
        @discardableResult
        package func update(
            id: String,
            fields: WebhookUpdateFields
        ) async throws -> Webhook {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "webhooks"
                    let id: String
                    let attributes: Attrs
                }
                struct Attrs: Encodable {
                    var url: String?
                    var name: String?
                    var eventTypes: [String]?
                    var secret: String?
                    var active: Bool?
                }
                let data: Data
            }
            let body = Body(data: .init(
                id: id,
                attributes: .init(
                    url: fields.url,
                    name: fields.name,
                    eventTypes: fields.eventTypes,
                    secret: fields.secret,
                    active: fields.active
                )
            ))
            struct Resp: Decodable { let data: Webhook }
            let resp: Resp = try await client.patch(
                path: "webhooks/\(id)",
                body: body,
                as: Resp.self
            )
            return resp.data
        }

        /// Delete a webhook subscription. Apple stops dispatching
        /// deliveries to the `url` and drops the historical
        /// `webhookDeliveries` records associated with it.
        package func delete(id: String) async throws {
            try await client.delete(path: "webhooks/\(id)")
        }
    }

    // MARK: - webhookDeliveries

    /// A single delivery attempt. Apple records one record per
    /// payload sent to the webhook `url`, including the HTTP
    /// response the endpoint returned. Read-only via this resource;
    /// the only write is the `resend` action below.
    package struct Delivery: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package let relationships: Relationships?

        package struct Attributes: Codable, Sendable {
            /// Identifier of the event type this delivery carries
            /// (e.g. "appStoreVersionState", "buildState", etc.).
            package let eventType: String?
            /// Current state of the delivery. Apple uses values like
            /// "SUCCESS", "FAILURE", and "PENDING" depending on
            /// whether the endpoint returned 2xx in time.
            package let state: String?
            /// How many times Apple has attempted this delivery.
            /// Apple retries failures a handful of times with
            /// exponential backoff before marking the delivery
            /// failed.
            package let attemptCount: Int?
            /// HTTP status code the endpoint returned on the last
            /// attempt, or nil if the call timed out before any
            /// status was received.
            package let responseCode: Int?
            /// Body the endpoint returned on the last attempt.
            /// Useful for debugging why a delivery is failing.
            package let responseBody: String?
            /// The exact JSON payload Apple POSTed (or attempted to
            /// POST) to the endpoint. Round-tripped as a string;
            /// callers that need the structured shape should
            /// JSON-decode it themselves.
            package let payload: String?
        }

        package struct Relationships: Codable, Sendable {
            package let webhook: WebhookRel?

            package struct WebhookRel: Codable, Sendable {
                package let data: Ref?
                package struct Ref: Codable, Sendable {
                    package let id: String
                    package let type: String
                }
            }
        }
    }

    /// Read-only delivery history. Lists are scoped per-webhook
    /// via `apps/{...}/webhooks/{id}/deliveries`; the get-by-id and
    /// resend endpoints work against the flat collection.
    package struct Deliveries {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        /// Lists delivery records for a single webhook. Use `cursor`
        /// to page; deliveries can pile up quickly for chatty
        /// event types.
        package func list(
            webhookID: String,
            limit: Int = 200,
            cursor: String? = nil
        ) async throws -> Page<Delivery> {
            let resp: PageEnvelope<Delivery> = try await client.get(
                path: "webhooks/\(webhookID)/deliveries",
                query: WebhooksAPI.listQuery(limit: limit, cursor: cursor),
                as: PageEnvelope<Delivery>.self
            )
            return .init(
                data: resp.data,
                nextCursor: WebhooksAPI.extractCursor(from: resp.links?.next)
            )
        }

        /// Fetches a single delivery by id. Returns nil on 404.
        package func get(id: String) async throws -> Delivery? {
            struct Resp: Decodable { let data: Delivery }
            do {
                let resp: Resp = try await client.get(
                    path: "webhookDeliveries/\(id)", as: Resp.self
                )
                return resp.data
            } catch let e as ASCClient.APIError where e.statusCode == 404 {
                return nil
            }
        }

        /// Action-style POST that retriggers an existing delivery.
        /// Apple's spec shape is
        /// `POST /v1/webhookDeliveries/{id}/relationships/retries`
        /// (a self-referential relationship link) with no body
        /// beyond the id in the path. The response carries the
        /// updated delivery record so callers can inspect the new
        /// attempt's outcome.
        @discardableResult
        package func resend(id: String) async throws -> Delivery {
            // Apple's "retry a delivery" action takes a JSON body of
            // shape {"data": {"type": "webhookDeliveryRetries"}} to
            // mark the resend intent. We send the documented
            // envelope; the response shape matches a delivery
            // record.
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "webhookDeliveryRetries"
                }
                let data: Data
            }
            let body = Body(data: .init())
            struct Resp: Decodable { let data: Delivery }
            let resp: Resp = try await client.post(
                path: "webhookDeliveries/\(id)/relationships/retries",
                body: body,
                as: Resp.self
            )
            return resp.data
        }
    }

    // MARK: - webhookPings

    /// A synthetic ping delivery. Creating one tells Apple to POST a
    /// canned payload to the target webhook's `url` so the developer
    /// can verify the endpoint is alive, reachable, and properly
    /// verifying signatures, without waiting for a real event.
    package struct Ping: Codable, Sendable {
        package let id: String
        package let attributes: Attributes?
        package let relationships: Relationships?

        package struct Attributes: Codable, Sendable {
            /// Mirrors the delivery state convention ("SUCCESS",
            /// "FAILURE", "PENDING") since a ping is just a synthetic
            /// delivery.
            package let state: String?
            /// HTTP status the endpoint returned on the ping. Nil if
            /// the call timed out before a status was received.
            package let responseCode: Int?
            /// Body the endpoint returned on the ping.
            package let responseBody: String?
        }

        package struct Relationships: Codable, Sendable {
            package let webhook: WebhookRel?

            package struct WebhookRel: Codable, Sendable {
                package let data: Ref?
                package struct Ref: Codable, Sendable {
                    package let id: String
                    package let type: String
                }
            }
        }
    }

    /// Pings namespace. Write-only collection used to dispatch a
    /// synthetic ping at a webhook URL.
    package struct Pings {
        package let client: ASCClient

        package init(client: ASCClient) {
            self.client = client
        }

        /// Dispatches a synthetic ping to the webhook's `url`. The
        /// returned `Ping` carries the endpoint's response so the
        /// caller can confirm reachability and signature
        /// verification in one round-trip.
        ///
        /// Apple's spec body is just
        /// `{data: {type: "webhookPings", relationships:
        /// {webhook: {data: {type: "webhooks", id: ...}}}}}` with no
        /// attributes.
        @discardableResult
        package func create(webhookID: String) async throws -> Ping {
            struct Body: Encodable {
                struct Data: Encodable {
                    let type = "webhookPings"
                    let relationships: Rels
                }
                struct Rels: Encodable {
                    struct Webhook: Encodable {
                        struct D: Encodable { let type = "webhooks"; let id: String }
                        let data: D
                    }
                    let webhook: Webhook
                }
                let data: Data
            }
            let body = Body(data: .init(
                relationships: .init(webhook: .init(data: .init(id: webhookID)))
            ))
            struct Resp: Decodable { let data: Ping }
            let resp: Resp = try await client.post(
                path: "webhookPings",
                body: body,
                as: Resp.self
            )
            return resp.data
        }
    }
}
