/// A `/api/random?count=3` response in jService's format. Written from
/// jService's documented response shape (the service is gone, so it couldn't
/// be captured live). Its second clue was flagged invalid by users; its third
/// is missing its category.
const jServiceRandomResponse = '''
[
  {
    "id": 87622,
    "answer": "<i>The Grapes of Wrath</i>",
    "question": "This 1939 novel follows the Joad family to California",
    "value": 400,
    "airdate": "2009-03-26T12:00:00.000Z",
    "created_at": "2014-02-14T02:13:42.587Z",
    "updated_at": "2014-02-14T02:13:42.587Z",
    "category_id": 11653,
    "game_id": null,
    "invalid_count": null,
    "category": {
      "id": 11653,
      "title": "american novels",
      "created_at": "2014-02-14T02:13:42.501Z",
      "updated_at": "2014-02-14T02:13:42.501Z",
      "clues_count": 5
    }
  },
  {
    "id": 4521,
    "answer": "a picture",
    "question": "Seen here",
    "value": 200,
    "airdate": "1998-11-02T12:00:00.000Z",
    "invalid_count": 2,
    "category": {"id": 33, "title": "art"}
  },
  {
    "id": 99,
    "answer": "Paris",
    "question": "Capital of France",
    "value": null,
    "airdate": "2001-01-01T12:00:00.000Z",
    "invalid_count": null
  }
]
''';
