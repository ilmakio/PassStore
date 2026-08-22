import Foundation

/// The words a generated passphrase is drawn from.
///
/// Written here rather than taken from a published list so the repository carries no third-party
/// licence for the sake of one array of nouns. Every word is short, common, unambiguous to type and
/// distinct from the others, which is the whole specification: a passphrase you cannot spell is one
/// you will replace with something worse.
///
/// The strength of a passphrase is `wordCount × log2(uniqueWords)`, so the count matters and is
/// therefore never hard-coded anywhere — `PassphraseGenerator` derives it from the list, and the
/// list is de-duplicated on load so a repeated word cannot quietly overstate the entropy.
nonisolated enum PassphraseWordList {
    /// Sorted and de-duplicated once, at first use.
    static let words: [String] = {
        var seen: Set<String> = []
        var result: [String] = []
        for word in raw.split(separator: " ") {
            let candidate = String(word)
            guard candidate.count >= 3, seen.insert(candidate).inserted else { continue }
            result.append(candidate)
        }
        return result.sorted()
    }()

    /// Bits contributed by each word drawn from this list.
    static var bitsPerWord: Double {
        let count = Double(words.count)
        guard count > 1 else { return 0 }
        return log2(count)
    }

    private static let raw = """
    able about above absent absorb abstract accent accept access accord account accuse ache acid \
    acorn acre across act action active actor actual adapt add adjust admire admit adopt adult \
    advance advice affair afford afraid after again against agent agree ahead aim air aisle alarm \
    album alert alien alike alive all alley allow almond almost alone along aloud alpha already \
    also alter always amaze amber amend among amount ample amuse anchor ancient anger angle animal \
    ankle annual answer ant anthem anxious any apart apex apology appeal appear apple apply april \
    apron arch area argue arise arm armor army around arrange arrest arrive arrow art artist ash \
    aside ask aspect asset assist assume atlas atom attach attack attend attic auction audio audit \
    august aunt author auto autumn avoid awake award aware away awful axis \
    baby back bacon badge bag bake balance balcony bald ball balloon bamboo banana band bank banner \
    bar barber bare bargain barn barrel base basic basin basket bat batch bath battery battle bay \
    beach bead beam bean bear beard beast beat beauty become bed bee beef before begin behave \
    behind being belief bell belong below belt bench bend benefit berry beside best bet better \
    between beyond bicycle bid big bike bill bind bird birth biscuit bit bitter black blade blame \
    blank blanket blast blaze bleak blend bless blind blink block blond blood bloom blot blouse \
    blow blue blunt blur board boast boat body boil bold bolt bomb bond bone bonus book boost boot \
    border bore borrow boss both bother bottle bottom bounce bound bow bowl box boy brace brain \
    brake branch brand brass brave bread break breath breeze brick bride bridge brief bright bring \
    brisk broad broken bronze brook broom brown brush bubble bucket budget buffet bug build bulb \
    bulk bull bunch bundle bunk burden burn burst bury bus bush business busy but butter button buy \
    buzz \
    cab cabin cable cactus cage cake calm camel camera camp can canal cancel candle candy cane \
    cannon canoe canvas canyon cap cape captain car carbon card care cargo carpet carrot carry cart \
    carve case cash cast castle casual cat catalog catch cattle cause cave cease cedar ceiling \
    celery cell cement census cent center century cereal certain chain chair chalk chamber chance \
    change chapel chapter charge charm chart chase cheap check cheek cheer cheese chef cherry chess \
    chest chew chief child chill chimney chin chip choice choose chop chorus chose chrome chunk \
    church cider cigar cinema circle circus cite citizen city civil claim clam clap clash clasp \
    class claw clay clean clear clerk clever click client cliff climb cling clinic clip cloak clock \
    clone close cloth cloud clover club clue clump coach coal coast coat cobra cocoa code coffee \
    coil coin cold collar collect colony color colt column comb combine come comedy comfort comic \
    command comment common compare compass compete complex concert concrete condition confirm \
    connect consent consist constant contact contain content contest context control convince cook \
    cool copper copy coral cord core cork corn corner correct cost cotton couch cough could council \
    count county couple courage course court cousin cover cow crack cradle craft crane crash crate \
    crawl crayon cream create credit creek crew cricket crime crisp critic crop cross crowd crown \
    cruel cruise crumb crush crust cry crystal cube cuff culture cup curb cure curious curl \
    current curtain curve cushion custom cut cycle \
    dad daily dairy daisy dam damage damp dance danger dare dark dash data date dawn day dead deaf \
    deal dear debate debris debt decade decay december decide deck declare decline decorate \
    decrease deep deer defeat defend define degree delay delete deliver demand denim dense dental \
    deny depart depend deposit depth derive descend desert deserve design desk detail detect \
    develop device devote diagram dial diamond diary dice diet differ dig digital dignity dim \
    dinner dinosaur direct dirt disagree discover dish dismiss display distance ditch dive divide \
    dizzy dock doctor document dodge dog doll dolphin domain dome donate donkey door dose dot double \
    doubt dough dove down dozen draft drag dragon drain drama draw dream dress drift drill drink \
    drip drive drop drown drum dry duck due dull dumb dune during dusk dust duty dwarf dwell dye \
    dynamic \
    each eager eagle ear early earn earth ease east easy eat echo eclipse edge edit educate effort \
    egg eight either elbow elder elect electric elegant element elephant elevator elite else email \
    embark embrace emerge emotion employ empty enable enact enclose encounter end endless endure \
    enemy energy enforce engage engine english enhance enjoy enlist enough enrich ensure enter \
    entire entry envelope envy equal equip erase erode error erupt escape escort essay essence \
    estate eternal ethics europe even evening event ever every evidence evil evoke exact example \
    exceed except excess exchange excite exclude excuse execute exercise exhaust exhibit exile \
    exist exit exotic expand expect expense expert expire explain explore export expose express \
    extend extra extreme eye \
    fabric face fact factor fade fail faint fair faith fall false fame family famous fan fancy far \
    farm fashion fast fat fate father fatigue fault favor fear feast feather february fee feed feel \
    fellow female fence fern ferry fetch fever few fiber fiction field fierce fifteen fifth fifty \
    fig fight figure file fill film filter final find fine finger finish fire firm first fiscal \
    fish fist fit five fix flag flame flap flash flat flavor flee fleet flesh flight flint flip \
    float flock flood floor flour flow flower fluid flush flute fly foam focus fog foil fold folk \
    follow food fool foot for force forest forget forgive fork form formal former fort fortune \
    forum forward fossil foster found four fourth fox frame free freeze freight french frequent \
    fresh friday friend fringe frog from front frost frown frozen fruit fuel full fun function fund \
    funny fur furnish further future \
    gadget gain galaxy gallery gallon game gap garage garden garlic garment gas gate gather gauge \
    gaze gear gem gender gene general gentle genuine german gesture ghost giant gift giggle ginger \
    giraffe girl give glad glance glass glide glimpse globe gloom glory glove glow glue goal goat \
    gold golf good goose gorilla govern gown grab grace grade grain gram grand grant grape graph \
    grasp grass grave gravity gray great green greet grid grief grill grin grind grip grit grocery \
    groom groove ground group grove grow guard guess guest guide guilt guitar gulf gum gut \
    habit hair half hall halt hammer hand handle hang happen happy harbor hard hardly harm harsh \
    harvest hat hatch hate haul haunt have hawk hazard haze head heal health heap hear heart heat \
    heaven heavy hedge heel height helium hello helmet help hen herb herd here hero hesitate hidden \
    hide high hill hint hip hire history hit hobby hockey hold hole holiday hollow holy home honest \
    honey honor hood hoof hook hope horizon horn horse hospital host hot hotel hour house hover how \
    hub huge human humble humid humor hunger hunt hurdle hurry hurt husband hut hybrid hydrogen \
    ice icon idea ideal identify idle ignore ill image imagine impact impose improve impulse inch \
    include income increase indeed index indoor infant inform inhale inherit initial inject injury \
    ink inland inner input inquiry insect inside insist inspect install instant instead insult \
    intact intend interest interior internal invent invest invite involve iron island issue item \
    ivory \
    jacket jaguar jail jam january jar jaw jazz jealous jeans jelly jewel job join joke journal \
    journey joy judge juice july jump june jungle junior jury just justify \
    keen keep kernel kettle key kick kid kidney kind king kiss kit kitchen kite kitten knee kneel \
    knife knight knit knob knock knot know \
    label labor lace lack ladder lady lake lamp land lane language lantern lap large laser last \
    late latin laugh launch laundry lava law lawn layer lazy lead leaf league leak lean leap learn \
    lease leather leave lecture left leg legal legend legion lemon lend length lens lesson let \
    letter level liar liberty library license lid lie life lift light like lilac limb lime limit \
    line linen link lion lip liquid list listen liter little live lizard load loan lobby local \
    locate lock lodge log logic lonely long look loop loose lord lose loss lost lot loud love low \
    loyal luck luggage lumber lunar lunch lung luxury \
    machine mad magic magnet maid mail main major make male mammal man manage mango manner mansion \
    manual many map marble march margin marine mark market marry marsh mask mass master mat match \
    material math matrix matter maximum may maybe mayor maze meadow meal mean measure meat medal \
    media medical medium meet melody melon melt member memory mend mention menu mercy mere merge \
    merit merry mesh message metal meter method middle midnight might mild mile milk mill mind mine \
    mineral minor mint minute mirror miss mist mix mobile model modern modest modify moist moment \
    monday money monitor monkey month mood moon moral more morning mosaic most mother motion motor \
    mount mourn mouse mouth move movie much mud mug multiply muscle museum mushroom music must \
    mutual mystery \
    nail naive name napkin narrow nation native nature navy near neat neck need needle negative \
    neglect neighbor neither nephew nerve nest net network neutral never new news next nice niece \
    night nine noble nod noise none noon nor normal north nose not note nothing notice novel \
    november now nowhere nuclear number nurse nut \
    oak oath obey object oblige observe obtain obvious occasion occupy occur ocean october odd odor \
    off offer office often oil old olive omit once one onion online only onto open opera opinion \
    oppose option orange orbit orchard order organ origin ornament orphan other ought ounce our \
    outdoor outer outline output outside oval oven over overcome owe owl own oxygen oyster \
    pace pack pad page pain paint pair palace pale palm pan panel panic paper parade parcel parent \
    park parrot part partner party pass past pasta patch path patient patrol pattern pause pave paw \
    pay peace peach peak peanut pear pearl peasant pebble pedal peel peer pen penalty pencil people \
    pepper per perch perfect perform perhaps period permit person pet phase phone photo phrase \
    physical piano pick picture pie piece pig pile pilgrim pill pillar pillow pilot pin pinch pine \
    pink pint pioneer pipe pirate pistol pit pitch pity pizza place plain plan plant plaster plastic \
    plate play plaza plea please pledge plenty plot plow plug plum plunge plus pocket poem poet \
    point poison polar pole police policy polish polite poll pond pony pool poor pop popular porch \
    pork port portion portrait pose position possible post pot potato pottery pouch pound pour \
    powder power practice praise pray precise predict prefer prepare present preserve press pretend \
    pretty prevent previous price pride primary prime prince print prior prison private prize \
    problem proceed process produce profile profit program project promise prompt proof proper \
    propose protect proud prove provide public pudding puff pull pulse pump punch pupil puppy \
    purchase pure purple purpose purse push put puzzle pyramid \
    quality quarter queen quest question queue quick quiet quilt quit quite quiz quote \
    rabbit race rack radar radio raft rail rain raise rally ramp ranch random range rank rapid rare \
    rate rather ratio raven raw ray reach react read ready real reason rebel recall receive recent \
    recipe record recover recruit red reduce refer reflect reform refuse regard region regret \
    regular reject relate relax release relief rely remain remark remedy remember remind remote \
    remove render renew rent repair repeat replace reply report request require rescue research \
    reserve resist resolve resort resource respect respond rest result resume retain retire retreat \
    return reveal reverse review reward rhythm rib ribbon rice rich ride ridge rifle right rigid \
    ring riot rip ripe rise risk ritual rival river road roar roast robe robin robot rock rocket \
    rod role roll roof room root rope rose rotate rough round route routine row royal rub rubber \
    ruby rude rug ruin rule rumor run rural rush rust \
    sack sad saddle safe sail saint salad salary sale salmon salon salt salute same sample sand \
    satisfy sauce sausage save saw say scale scan scar scarce scare scarf scatter scene scent \
    schedule scheme scholar school science scissors scoop scope score scout scrap scratch screen \
    screw script scrub sculpt sea seal search season seat second secret section secure seed seek \
    seem segment seize seldom select self sell send senior sense sentence separate september series \
    serious serve session settle seven severe sew shade shadow shaft shake shall shallow shame \
    shape share shark sharp shave shed sheep sheet shelf shell shelter shield shift shine ship \
    shirt shock shoe shoot shop shore short should shoulder shout shove show shower shrimp shrink \
    shrug shuffle shut shy sibling sick side siege sigh sight sign silent silk silly silver similar \
    simple since sing single sink sip sir sister sit site situate six size skate sketch ski skill \
    skin skip skirt skull sky slab slam sleep sleeve slender slice slide slight slim slip slogan \
    slope slot slow small smart smash smell smile smoke smooth snack snake snap sneak sniff snow \
    soap social sock soda sofa soft soil solar soldier sole solid solve some son song soon sorry \
    sort soul sound soup source south space spare spark speak special speech speed spell spend \
    sphere spice spider spill spin spirit spit split spoil sponge spoon sport spot spray spread \
    spring sprout spy square squeeze squirrel stable stack stadium staff stage stair stake stamp \
    stand star start state station statue stay steady steak steal steam steel steep steer stem step \
    stereo stick stiff still sting stir stitch stock stomach stone stool stop store storm story \
    stove strand strange straw stream street stress stretch strike string strip stroke strong \
    struggle student study stuff stumble style subject submit subway succeed such sudden suffer \
    sugar suggest suit summer summit sun super supply support suppose supreme sure surface surge \
    surprise surround survey survive suspect sustain swallow swamp swan swap swarm sway swear sweat \
    sweep sweet swell swift swim swing switch sword symbol symptom syrup system \
    table tackle tag tail tailor take tale talent talk tall tank tap tape target task taste tax tea \
    teach team tear tease tell temper temple tempt ten tenant tend tender tennis tense tent term \
    terrace test text thank that theme then theory there these they thick thief thin thing think \
    third thirst thirty this thorn those though thought thread three thrive throat throne through \
    throw thumb thunder thursday thus ticket tide tidy tie tiger tight tile till timber time tin \
    tiny tip tire title toast today toe together toilet token tomato tomorrow ton tone tongue \
    tonight too tool tooth top topic torch total touch tough tour toward towel tower town toy trace \
    track trade traffic tragic trail train trait tram transfer trap trash travel tray treat tree \
    trend trial tribe trick trigger trim trip triumph trolley troop tropical trouble truck true \
    truly trumpet trunk trust truth try tube tuesday tug tumble tuna tune tunnel turkey turn turtle \
    twelve twenty twice twin twist two type typical \
    ugly ultimate umbrella unable uncle under undergo uniform union unique unit universe unknown \
    unless unlock until unusual upgrade uphold upon upper upset urban urge usage use useful usual \
    utility \
    vacant vacuum vague valid valley value valve van vanish vapor variety various vary vase vast \
    vault vegetable vehicle veil vein velvet vendor venture verb verdict verify verse version very \
    vessel veteran viable vibrant victory video view village vinegar violet violin virtual virtue \
    visa visible vision visit visual vital vivid vocal voice void volcano volume volunteer vote \
    vowel voyage \
    wafer wage wagon waist wait wake walk wall walnut wander want ward warm warn warrant wash wasp \
    waste watch water wave wax way weak wealth weapon wear weather weave wedding wednesday weed \
    week weigh weird welcome weld well west wet whale wheat wheel when where which while whip \
    whisper whistle white who whole why wide widow width wife wild will willow win wind window wine \
    wing wink winter wipe wire wisdom wise wish witness wolf woman wonder wood wool word work world \
    worm worry worth wound wrap wreck wrist write wrong \
    yard yarn yawn year yellow yes yesterday yet yield yoga yogurt young youth \
    zebra zero zinc zone zoo
    """
}
