import Foundation

/// One notification Steam produced, as the context page reports it.
///
/// Steam hands its UI a notification id, a type, and a protobuf body whose
/// shape is chosen by that type. The page deserializes it with Steam's own
/// per-type descriptor and resolves the identities only it can resolve — an
/// account id to a persona, an app id to a game's name — so what arrives here
/// is already a set of names. The words are written on this side.
struct SteamNotification: Decodable, Equatable, Sendable {
    /// Steam's `ENotificationType`. The client's table runs 1…64; the ones
    /// the Steam toast UI presents are handled by Steam itself.
    var kind: Int
    /// Steam's `ENotificationSource`: 1 is the client, 2 is the Steam
    /// servers. Only the client's are presented — a server notification's
    /// body is a JSON blob whose rendering is Steam's own web component.
    var source: Int
    var id: String
    /// The sender's persona for a message, the group's name for a group chat.
    var title: String
    var body: String
    /// The sender's avatar, on Steam's CDN.
    var icon: String
    var steamID: String
    /// The 32-bit account id — what Steam's own chat calls take.
    var accountID: String
    var appID: String
    var gameName: String
    /// Steam's own sound setting for this notification, answered in the page
    /// where it lives: the per-friend override over Friends & Chat's "play a
    /// sound when I receive a message" for a message, the chat-room switch
    /// for a group's. Absent from a payload an older page built, which reads
    /// as the silence that was the behavior then.
    var playsSound: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind
        case source
        case id
        case title
        case body
        case icon
        case steamID = "steamid"
        case accountID = "accountid"
        case appID = "appid"
        case gameName
        case playsSound = "sound"
    }
}

