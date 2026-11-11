-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

module Test.Kupo.Data.PatternSpec
    ( spec
    ) where

import Kupo.Prelude

import Kupo.Data.Cardano
    ( ComparableOutput
    , ExtendedOutputReference
    , Output
    , emptyMetadata
    , getPointSlotNo
    , toComparableOutput
    , unsafeBinaryDataFromBytes
    )
import Kupo.Data.PartialBlock
    ( PartialBlock (..)
    , PartialTransaction (..)
    )
import Kupo.Data.Pattern
    ( Codecs (..)
    , Match (consumed)
    , MatchBootstrap (..)
    , Pattern (..)
    , includes
    , matchBlock
    , matching
    , overlaps
    , patternFromText
    )
import Test.Hspec
    ( Spec
    , context
    , parallel
    , shouldBe
    , specify
    )
import Test.Hspec.QuickCheck
    ( prop
    )
import Test.Kupo.Data.Generators
    ( genNonGenesisPoint
    , genOutputReference
    , genTransactionId
    )
import Test.Kupo.Data.Pattern.Fixture
    ( matches
    , patterns
    )
import Test.QuickCheck
    ( Gen
    , counterexample
    , elements
    , forAll
    , (===)
    , (==>)
    )

import qualified Data.ByteString as BS
import qualified Data.Map as Map
import qualified Data.Set as Set

spec :: Spec
spec = parallel $ do
    context "patternFromText" $ forM_ patterns $ \(str, expectation, _) -> do
        specify (toString str) $ do
            patternFromText str `shouldBe` Just expectation

    context "matching" $ forM_ patterns $ \(str, p, matches') -> do
        specify (toString str) $ do
            let
                got = sort (p `matchAll` matches)
                expected = sort (map (second toComparableOutput) matches')
             in
                got `shouldBe` expected

    prop "p1 includes p2 => matches(p2) ⊆ matches(p1)" $
        forAll genPattern $ \p1 ->
            forAll genPattern $ \p2 ->
                p1 `includes` p2 ==>
                    let
                        m1 = Set.fromList (p1 `matchAll` matches)
                        m2 = Set.fromList (p2 `matchAll` matches)
                    in
                        (m2 `Set.isSubsetOf` m1)
                            & counterexample ("matches(p2): " <> show m2)
                            & counterexample ("matches(p1): " <> show m1)

    prop "includes is reflexive" $
        forAll genPattern $ \p1 ->
            p1 `includes` p1

    prop "includes is antisymmetric" $
        forAll genPattern $ \p1 ->
            forAll genPattern $ \p2 ->
                p1 `includes` p2 ==>
                    if p2 `includes` p1 then
                        p1 == p2
                    else
                        p1 /= p2

    prop "p1 includes p2 => p1 overlaps [p2]" $
        forAll genPattern $ \p1 ->
            forAll genPattern $ \p2 ->
                p1 `includes` p2 ==>
                    p1 `overlaps` (Set.singleton p2)

    context "matchBlock" $ do
        prop "numbers spent inputs and their redeemers in ascending input order" $
            forAll ((,,,) <$> genNonGenesisPoint <*> genTransactionId <*> genOutputReference <*> genOutputReference) $
                \(pt, txId, ref1, ref2) -> ref1 /= ref2 ==> do
                    let (lo, hi) = if ref1 < ref2 then (ref1, ref2) else (ref2, ref1)
                    let redeemerLo = unsafeBinaryDataFromBytes $ BS.pack [1]
                    let redeemerHi = unsafeBinaryDataFromBytes $ BS.pack [2]
                    let tx = PartialTransaction
                            { id = txId
                            , inputs = [hi, lo]
                            , outputs = []
                            , datums = mempty
                            , spendRedeemers = Map.fromList [(0, redeemerLo), (1, redeemerHi)]
                            , scripts = mempty
                            , metadata = Nothing
                            }
                    let blk = PartialBlock { blockPoint = pt, blockBody = [tx], isDijkstraBlock = False }
                    let codecs = Codecs
                            { toResult = identity
                            , toBinaryData = \_ _ -> ()
                            , toScript = \_ _ -> ()
                            , toPolicy = \_ _ -> ()
                            }
                    let patterns' = Set.singleton (MatchAny IncludingBootstrap)
                    let got = Map.lookup (txId, getPointSlotNo pt) $ consumed $ matchBlock codecs patterns' blk
                    got === Just
                        [ (MatchOutputReference lo, 0, Just redeemerLo)
                        , (MatchOutputReference hi, 1, Just redeemerHi)
                        ]

--
-- Helper
--

matchAll
    :: Pattern
    -> [(ExtendedOutputReference, Output)]
    -> [(ExtendedOutputReference, ComparableOutput)]
matchAll p xs =
    [ (outRef, toComparableOutput out)
    | (outRef, out) <- xs
    , isJust (matching (fst outRef) out emptyMetadata p)
    ]

genPattern :: Gen Pattern
genPattern =
    elements [ p | (_, p, _) <- patterns ]
