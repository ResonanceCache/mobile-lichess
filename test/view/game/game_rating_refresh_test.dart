import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/model/account/account_repository.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/common/perf.dart';
import 'package:lichess_mobile/src/model/common/time_increment.dart';
import 'package:lichess_mobile/src/model/game/game_controller.dart';
import 'package:lichess_mobile/src/model/lobby/game_seek.dart';
import 'package:lichess_mobile/src/model/lobby/game_setup_preferences.dart';
import 'package:lichess_mobile/src/model/user/user.dart';
import 'package:lichess_mobile/src/network/http.dart';
import 'package:lichess_mobile/src/view/game/game_body.dart';
import 'package:lichess_mobile/src/view/game/game_screen.dart';
import 'package:lichess_mobile/src/view/game/game_screen_providers.dart';
import 'package:material_ui/material_ui.dart';

import '../../model/auth/fake_auth_storage.dart';
import '../../model/game/game_socket_example_data.dart';
import '../../network/fake_http_client_factory.dart';
import '../../network/fake_websocket_channel.dart';
import '../../test_helpers.dart';
import '../../test_provider_scope.dart';

const _gameFullId = GameFullId('qVChCOTcHSeW');

String _accountJson(int blitzRating) =>
    '''
{"id":"testuser","username":"testUser","createdAt":1290415680000,"seenAt":1290415680000,"perfs":{"blitz":{"games":100,"rating":$blitzRating,"rd":60,"prog":0}}}
''';

String _ratedFullEvent() => makeFullEvent(
  const GameId('qVChCOTc'),
  '',
  whiteUserName: 'testUser',
  blackUserName: 'Steven',
  youAre: .white,
).replaceFirst('"rated": false', '"rated": true');

void main() {
  /// A client whose `/api/account` blitz rating is taken from [ratings], one per request (the last
  /// one is repeated), and that records the rating range of every lobby seek.
  ({MockClient client, List<String?> seekRanges, List<int> accountRequests}) makeClient(
    List<int> ratings,
  ) {
    final seekRanges = <String?>[];
    final accountRequests = <int>[];
    final client = MockClient((request) async {
      if (request.url.path == '/api/account') {
        final rating = ratings[accountRequests.length.clamp(0, ratings.length - 1)];
        accountRequests.add(rating);
        return http.Response(_accountJson(rating), 200);
      } else if (request.url.path == '/api/board/seek' && request.method == 'POST') {
        seekRanges.add(request.bodyFields['ratingRange']);
        return http.Response('ok', 200);
      }
      return await mockResponse('', 404);
    });
    return (client: client, seekRanges: seekRanges, accountRequests: accountRequests);
  }

  Future<ProviderContainer> pumpGameScreen(
    WidgetTester tester, {
    required MockClient client,
    required GameScreenSource source,
  }) async {
    final app = await makeTestProviderScopeApp(
      tester,
      home: GameScreen(source: source),
      authUser: fakeAuthUser,
      overrides: {
        httpClientFactoryProvider: httpClientFactoryProvider.overrideWith(
          (ref) => FakeHttpClientFactory(() => client),
        ),
      },
    );
    await tester.pumpWidget(app);
    final container = ProviderScope.containerOf(tester.element(find.byType(GameScreen)));
    // In the app, the account provider is kept alive for the whole session by the AccountService.
    container.listen(accountProvider, (_, _) {});
    return container;
  }

  Future<void> startAndFinishGame(WidgetTester tester) async {
    sendServerSocketMessages(Uri(path: '/lobby/socket/v5'), [
      '{"t": "redirect", "d": {"id": "${_gameFullId.value}" }, "v": 1}',
    ]);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(kFakeWebSocketConnectionLag);
    sendServerSocketMessages(GameController.socketUri(_gameFullId), [_ratedFullEvent()]);
    await tester.pump();

    sendServerSocketMessages(GameController.socketUri(_gameFullId), [
      '{"t":"endData","d":{"status":"resign","winner":"white","ratingDiff":{"white":8,"black":-8}}}',
    ]);
    await tester.pump(const Duration(milliseconds: 10));
    // wait for the result dialog and for its buttons to activate
    await tester.pump(kGameEndDialogDelay);
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('new opponent seek uses the rating updated after the previous game', (tester) async {
    final (:client, :seekRanges, :accountRequests) = makeClient([1500, 1508]);
    final setup = GameSetupPrefs.defaults.copyWith(
      timeIncrement: const TimeIncrement(180, 2),
      customRatingDelta: (-100, 100),
    );
    // the account as loaded on the play screen, before the first game
    final initialAccount = User.fromServerJson(
      jsonDecode(_accountJson(1500)) as Map<String, dynamic>,
    );

    final container = await pumpGameScreen(
      tester,
      client: client,
      source: LobbySource(GameSeek.custom(setup, initialAccount)),
    );
    await tester.pump(kFakeWebSocketConnectionLag);
    await tester.pump(const Duration(milliseconds: 100));

    expect(seekRanges, ['1400-1600']);
    expect(find.text('1400-1600'), findsOneWidget);

    await startAndFinishGame(tester);

    // the account has been reloaded after the rated game ended
    expect(accountRequests, [1500, 1508]);
    expect((await container.read(accountProvider.future))?.perfs[Perf.blitz]?.rating, 1508);

    await tester.tap(find.widgetWithText(FilledButton, 'New opponent'));
    await tester.pump(kFakeWebSocketConnectionLag);
    await tester.pump(const Duration(milliseconds: 100));

    expect(seekRanges, ['1400-1600', '1408-1608']);
    expect(find.text('1408-1608'), findsOneWidget);

    // cancel the pending seek
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: kPlatformVariant);
}
