/// An item of `GET /api/staff_picks`: the model is nested under
/// `character_model` instead of being the item itself.
struct VRoidStaffPick: Decodable, Sendable {
    let characterModel: VRoidCharacterModel?

    enum CodingKeys: String, CodingKey {
        case characterModel = "character_model"
    }
}
