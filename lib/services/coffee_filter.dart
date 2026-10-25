// Coffee-relevance filter: decides whether a post's text is about coffee.
//
// Used client-side for an instant approved/pending status, and mirrored
// in `functions/index.js` (the Cloud Function re-checks authoritatively
// and notifies admins). Keep the two lists in sync.
//
// Matching is deliberately generous: a false positive just lets a post
// through, while a false negative holds a good post for review. Words
// match whole-word only ('bean' must not match 'beanie'); phrases match
// as substrings on normalized text.

/// Single coffee words, lowercase, accents stripped.
const coffeeKeywords = {
  'coffee',
  'cafe',
  'espresso',
  'latte',
  'cappuccino',
  'mocha',
  'americano',
  'macchiato',
  'cortado',
  'bean',
  'beans',
  'roast',
  'roasting',
  'roaster',
  'torrefaction',
  'brew',
  'brewing',
  'brasseur',
  'barista',
  'grinder',
  'moulin',
  'crema',
  'arabica',
  'robusta',
  'decaf',
  'blend',
  'origin',
  'origine',
  'caffeine',
  'cafeine',
  'percolator',
  'keurig',
  'nespresso',
  'drip',
  'filter',
  'filtre',
  'iced',
  'affogato',
  'ristretto',
  'lungo',
  'doppio',
  'turkish',
  'moka',
  'carafe',
  'cup',
  'tasse',
  'mug',
  'milk',
  'lait',
  'sip',
  'tasting',
  'degustation',
  'aroma',
  'arome',
  'flavour',
  'flavor',
  'saveur',
  'chocolate',
  'chocolat',
  'caramel',
  'fruity',
  'fruite',
  'nutty',
  'floral',
  'extraction',
  'grind',
  'mouture',
  'dose',
  'tamper',
  'portafilter',
  'kettle',
  'bouilloire',
  'scale',
  'balance',
  'timer',
  'recipe',
  'recette',
  'method',
  'methode',
  'aeropress',
  'chemex',
  'v60',
  'pourover',
  'coldbrew',
  'siphon',
  'kalita',
  'melitta',
};

/// Multi-word coffee phrases, lowercase, accents stripped.
const coffeePhrases = [
  'flat white',
  'cold brew',
  'french press',
  'pour over',
  'coffee shop',
  'coffee bean',
  'coffee beans',
  'coffee lover',
  'coffee lovers',
  'oat milk',
  'lait d avoine',
  'coffee break',
  'pause cafe',
  'morning coffee',
  'coffee time',
  'coffee run',
  'coffee date',
  'coffee machine',
  'machine a cafe',
  'coffee maker',
  'coffee cup',
  'tasse de cafe',
  'cup of coffee',
  'latte art',
  'coffee grounds',
  'marc de cafe',
  'coffee filter',
  'filtre a cafe',
  'coffee grinder',
  'moulin a cafe',
  'coffee roaster',
  'torrefacteur',
  'coffee bar',
  'coffee house',
  'coffee recipe',
  'recette de cafe',
  'coffee tasting',
  'degustation de cafe',
];

const _accents = {
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'à': 'a',
  'â': 'a',
  'ç': 'c',
  'î': 'i',
  'ï': 'i',
  'ô': 'o',
  'ù': 'u',
  'û': 'u',
  'ü': 'u',
  'ä': 'a',
  'ö': 'o',
  'ÿ': 'y',
  'æ': 'ae',
  'œ': 'oe',
};

String _normalize(String input) {
  var s = input.toLowerCase();
  _accents.forEach((k, v) => s = s.replaceAll(k, v));
  return s;
}

/// True when the post text is about coffee (word or phrase match).
bool isCoffeeRelated(String body) {
  final text = _normalize(body);
  for (final phrase in coffeePhrases) {
    if (text.contains(phrase)) return true;
  }
  final words = text.split(RegExp(r'[^a-z0-9]+'));
  for (final word in words) {
    if (word.isNotEmpty && coffeeKeywords.contains(word)) return true;
  }
  return false;
}
