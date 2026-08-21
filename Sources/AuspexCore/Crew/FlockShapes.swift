import AgentSessionKit
import AgentSessionLive
import Foundation

/// Which body every bird on the flock wall wears, and how one is chosen.
///
/// ## Shape is not identity here — colour is
///
/// The wall used to give each harness a silhouette: Claude a circle, Cursor a
/// triangle, Grok Bot a droplet. It looked deliberate on a board of eight and
/// wrong on a board of ninety, because a wall where forty birds are the same
/// triangle is a wall with one bird on it repeated forty times. The thing a
/// person is actually picking out is *this session, the one I was watching* —
/// and the accent already says which harness it is, on the card's rail, in the
/// sidebar's dots, and on the mark beside the title.
///
/// So the shape is **seeded by the session** and the colour is the harness. Two
/// Codex sessions are two different creatures in the same teal; the harness is
/// as legible as it was, and the wall stops being wallpaper.
///
/// ## Plump only
///
/// Every shape in this family satisfies one bound: its smallest radius is at
/// least ``plumpness`` of its largest. That is the whole of the rule, and it is
/// asserted in the suite rather than left to taste. A tip, a point or a long
/// ray reads as spiky at 56 points and disappears at 22 — and the members' mini
/// avatars are drawn at 22 out of the same family, so a shape that fails there
/// fails everywhere.
///
/// The ten are modelled on the characters in the avatar lab's picker — a round
/// one, a fat squircle, a bean, a cloud, a rounded cube with two ear blobs, a
/// fat lemon, a blob with a side foot, a ghost with a scalloped hem, a sun, and
/// bloub's own pebble. They are *silhouettes* taken from those: the lab builds
/// its bodies out of spheres and cubes in three dimensions, and none of that
/// is ported here — a radial profile is what the engine morphs between, and
/// staying inside it is what keeps every shape able to become every other one.
public enum FlockShapes {
    /// The smallest radius any body in this family may have, as a fraction of
    /// its largest.
    ///
    /// 0.72. Below it a shape starts to have a *direction* — a nose, a tip, a
    /// spike — and the wall's whole language is that direction means gaze.
    public static let plumpness = 0.72

    /// The bodies the flock draws from, in a fixed order.
    ///
    /// Ten, and the number is load-bearing: a person watching ten sessions
    /// should be able to tell all ten apart, so there has to be a shape for
    /// each of them. Fixed order because the assignment below indexes into it,
    /// and a wall that reshuffled every avatar when a shape was added would
    /// throw away everything the reader had learned.
    public static let family: [BloubShapeID] = [
        .circle, .squircle, .pebble, .bean, .cloud,
        .eared, .lemon, .footed, .ghost, .sun,
    ]

    /// The body one session wears.
    ///
    /// A pure function of its key, so it survives a relaunch, a re-sort and a
    /// frame that dropped the session and got it back — the avatar a person
    /// was watching is the same avatar afterwards. Nothing about the harness
    /// enters into it.
    public static func shape(for key: SessionKey) -> BloubShapeID {
        family[index(for: key.description)]
    }

    /// The same question asked of any string, for the tests and for anything
    /// that has a name rather than a key.
    public static func shape(seed: String) -> BloubShapeID {
        family[index(for: seed)]
    }

    /// Which slot of the family a seed lands in.
    ///
    /// FNV-1a and then a final avalanche mix. The mix is the part that matters:
    /// session ids differ in their last few characters far more often than in
    /// their first, and FNV alone leaves those differences in the low bits —
    /// so ten sessions minted a second apart would have marched through the
    /// family in order, or worse, sat in two of its slots.
    static func index(for seed: String) -> Int {
        var hash = TaskShortID.fnv1a(seed)
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        hash = hash &* 0xc4ce_b9fe_1a85_ec53
        hash ^= hash >> 33
        return Int(hash % UInt64(family.count))
    }

    /// Whether a body is plump enough to be in the family.
    ///
    /// Exposed so the suite can assert it over the whole catalogue rather than
    /// over a list somebody remembered to update.
    public static func isPlump(_ radii: [Double]) -> Bool {
        guard let low = radii.min(), let high = radii.max(), high > 0 else { return false }
        return low / high >= plumpness
    }
}
