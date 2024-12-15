import {
  OutputSchema as RepoEvent,
  isCommit,
} from './lexicon/types/com/atproto/sync/subscribeRepos'
import { FirehoseSubscriptionBase, getOpsByType } from './util/subscription'
import fs from 'fs'

const excludedText: string[] = [
  '1 like',
  '4chan',
  '5 faves',
  '8chan',
  'TTRPGRising',
  'about me',
  'critical role',
  'deviantart',
  'elon',
  'for each like',
  'get to know me',
  'get to know my',
  'hot take',
  'hottake',
  'introduce yourself',
  'intropost',
  'nft',
  'osréalacha',
  'OSRFood',
  'pathfinder',
  'promosky',
  'self-promo',
  'selfpromosaturday',
  'SELF PROMO SATURDAY',
  'Spicy take',
  'tag yourself',
  'trump',
  'wotc',
]

const matchPatterns: RegExp[] = [
  // OSR hashtags / games
  /(^|\s)#?ICRPG(\s|\W|$)/im,
  /(^|\s)#?odnd(\s|\W|$)/im,
  /(^|\s)#?CairnRPG(\s|\W|$)/im,
  /(^|\s)#?whitebox(\s|\W|$)/im,
  /(^|\s)#?BECMI(\s|\W|$)/im,
  /(^|\s)#?DCCRPG(\s|\W|$)/im,
  /(^|\s)#?MCCRPG(\s|\W|$)/im,
  /(^|\s)#?bfrpg(\s|\W|$)/im,
  /(^|\s)#?mausritter(\s|\W|$)/im,
  /(^|\s)#?bastionland(\s|\W|$)/im,
  /(^|\s)#?b\/x(\s|\W|$)/im,
  /(^|\s)#?basic\/expert(\s|\W|$)/im,

  // OSR games
  /(^|\s)Classic Traveller(\s|\W|$)/im,
  /(^|\s)Between Two Cairns(\s|\W|$)/im,
  /(^|\s)Tunnel Goons(\s|\W|$)/im,
  /(^|\s)The Black Hack(\s|\W|$)/im,
  /(^|\s)Swords & Wizardry(\s|\W|$)/im,
  /(^|\s)Index Card RPG(\s|\W|$)/im,
  /(^|\s)old school essentials(\s|\W|$)/im,
  /(^|\s)dungeon crawl classics(\s|\W|$)/im,

  // OSR games that are mixed up easily, only include if RPG is also mentioned
  /(^|\s)#?Knave\s*RPG(\s|\W|$)/im,
  /(^|\s)#?Mothership\s*RPG(\s|\W|$)/im,
  /(^|\s)#?cairn\s*RPG(\s|\W|$)/im,
  /(^|\s)#?bx\s*RPG(\s|\W|$)/im,
  /(^|\s)beyond the wall\s*RPG(\s|\W|$)/im,
  /(^|\s)into the odd\s*RPG(\s|\W|$)/im,

  // OSR terms that get pulled in for video game discussion too often
  /(^|\s)#?osr(\s|\W|$)(?!.*(computer|video game|pc|console))/im,
]

const prohibitedUrls: string[] = [
  'https://osr.statisticsauthority.gov.uk',
  'osr.statisticsauthority.gov.uk',
]

// Load banned DIDs
const bannedUsersFile = './bannedUsers.json'
let bannedUsers: string[] = []
try {
  bannedUsers = JSON.parse(fs.readFileSync(bannedUsersFile, 'utf8'))
} catch (err) {
  console.error(`Failed to load banned users from ${bannedUsersFile}:`, err)
}

export class FirehoseSubscription extends FirehoseSubscriptionBase {
  async handleEvent(evt: RepoEvent) {
    if (!isCommit(evt)) return

    const ops = await getOpsByType(evt)

    const postsToDelete = ops.posts.deletes.map((del) => del.uri)

    const postsToCreate = ops.posts.creates
      // remove posts from banned users
      .filter((create) => !bannedUsers.includes(create.author))
      .filter((create) => {
        const txt = create.record.text.toLowerCase()

        const no_bad_urls = !prohibitedUrls.some((url) => txt.includes(url))
        const no_excluded_words = !excludedText.some((term) => txt.includes(term))
        const found_osr_terms = matchPatterns.some((pattern) => pattern.test(txt))

        // Check for list-like content
        const lines = txt.split('\n')
        const shortLinesCount = lines.filter((line) => {
          const wordCount = line.trim().split(/\s+/).length
          return line.trim() !== '' && wordCount < 5
        }).length
        const no_lists = shortLinesCount < 5

        // Check if the post is only hashtags
        const tokens = txt.trim().split(/\s+/)
        const onlyHashtags = tokens.length > 0 && tokens.every((token) =>
          /^#[\p{L}\p{N}_]+$/u.test(token)
        )

        return no_bad_urls && no_excluded_words && no_lists && found_osr_terms && !onlyHashtags
      })
      .map((create) => {
        console.log(`Found post by ${create.author}: ${create.record.text}`)
        return {
          uri: create.uri,
          cid: create.cid,
          indexedAt: new Date().toISOString(),
        }
      })

    // nuke bad posts
    if (postsToDelete.length > 0) {
      await this.db
        .deleteFrom('post')
        .where('uri', 'in', postsToDelete)
        .execute()
    }

    // create good posts
    if (postsToCreate.length > 0) {
      await this.db
        .insertInto('post')
        .values(postsToCreate)
        .onConflict((oc) => oc.doNothing())
        .execute()
    }
  }
}
