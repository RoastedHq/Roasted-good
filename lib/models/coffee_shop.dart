/// Launch regions: the cities the app serves right now. Step 1 of the
/// launch is Toronto only; add 'Ottawa' and 'Gatineau' for step 2.
/// Shops outside these regions stay in the catalogue but are hidden
/// everywhere (map, list, perks, where-to-buy), so re-enabling a city
/// is a one-line change here.
const launchShopRegions = {'Toronto'};
class CoffeeShop {
  const CoffeeShop({
    required this.id,
    required this.name,
    required this.address,
    required this.region,
    this.latitude,
    this.longitude,
    this.approximate = false,
  });

  final String id;
  final String name;
  final String address;

  /// City region: 'Gatineau', 'Ottawa' or 'Toronto'. Used to group
  /// the shop list on the map screen.
  final String region;
  final double? latitude;
  final double? longitude;

  /// True when the pin is an approximate neighbourhood location,
  /// not the exact storefront.
  final bool approximate;

  Map<String, dynamic> toMap() => {
        'name': name,
        'address': address,
        'region': region,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        'approximate': approximate,
      };

  factory CoffeeShop.fromMap(Map<String, dynamic> map, String id) {
    return CoffeeShop(
      id: id,
      name: (map['name'] ?? '') as String,
      address: (map['address'] ?? '') as String,
      region: (map['region'] ?? 'Ottawa') as String,
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      approximate: (map['approximate'] ?? false) as bool,
    );
  }
}
