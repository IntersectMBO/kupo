-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

module Test.Kupo.Data.OgmiosSpec
    ( spec
    ) where

import Kupo.Prelude

import Data.List
    ( (!!)
    )
import Kupo.App.ChainSync.Ogmios
    ( intersectionNotFound
    )
import Kupo.Data.Cardano
    ( IsBlock (..)
    , UnsupportedSubTransactions (..)
    )
import Kupo.Data.Ogmios
    ( NextBlockResponse (..)
    , PartialBlock
    , decodeFindIntersectionResponse
    , decodeNextBlockResponse
    )
import System.Directory
    ( listDirectory
    )
import System.FilePath
    ( (</>)
    )
import Test.Hspec
    ( Expectation
    , Spec
    , SpecWith
    , context
    , expectationFailure
    , it
    , parallel
    , runIO
    , shouldSatisfy
    )
import Test.Hspec.QuickCheck
    ( prop
    )
import Test.QuickCheck
    ( counterexample
    , withNumTests
    )
import Test.QuickCheck.Monadic
    ( assert
    , monadicIO
    , monitor
    , run
    )

import qualified Data.Text as Text

import Data.Aeson as Json
import Data.Aeson.Types as Json

spec :: Spec
spec = parallel $ context "can decode relevant Ogmios' test vectors" $ do
    context "decodeFindIntersectResponse" $ do
        let dir = "./test/vectors/ogmios/server/test/vectors/FindIntersectionResponse"
        vectors <- runIO (listDirectory dir)
        propVector ((dir </>) <$> vectors) (decodeFindIntersectionResponse $ intersectionNotFound [])

    context "decodeRequestNextResponse" $ do
        let dir = "./test/vectors/ogmios/server/test/vectors/NextBlockResponse"
        vectors <- runIO (listDirectory dir)
        propVector ((dir </>) <$> vectors) decodeNextBlockResponse

    context "decodeRequestNextResponse (extra golden)" $ do
        let dir = "./test/vectors/golden"
        vectors <- runIO (listDirectory dir)
        propVector ((dir </>) <$> vectors) decodeNextBlockResponse

    context "checkSubTransactions" $ do
        it "rejects a Dijkstra block, whose transactions Ogmios does not serialise" $ do
            let stub = Json.object
                    [ "id" .= txId
                    , "spends" .= ("inputs" :: Text)
                    ]
            withBlock (nextBlock "dijkstra" [stub]) $ \blk ->
                checkSubTransactions blk `shouldSatisfy` \case
                    Left UnverifiableSubTransactions{} -> True
                    _ -> False

        it "accepts a Conway block" $ do
            let tx = Json.object
                    [ "id" .= txId
                    , "spends" .= ("inputs" :: Text)
                    , "inputs" .= ([] :: [Json.Value])
                    , "outputs" .= ([] :: [Json.Value])
                    ]
            withBlock (nextBlock "conway" [tx]) $ \blk ->
                checkSubTransactions blk `shouldSatisfy` isRight

withBlock :: Json.Value -> (PartialBlock -> Expectation) -> Expectation
withBlock value check =
    case Json.parse decodeNextBlockResponse value of
        Json.Success (RollForward _ blk) -> check blk
        Json.Success _ -> expectationFailure "expected a roll forward"
        Json.Error str -> expectationFailure str

nextBlock :: Text -> [Json.Value] -> Json.Value
nextBlock era txs = Json.object
    [ "result" .= Json.object
        [ "direction" .= ("forward" :: Text)
        , "tip" .= point
        , "block" .= Json.object
            [ "type" .= ("praos" :: Text)
            , "era" .= era
            , "id" .= blockId
            , "height" .= (1 :: Int)
            , "slot" .= (42 :: Int)
            , "transactions" .= txs
            ]
        ]
    ]
  where
    point = Json.object
        [ "id" .= blockId
        , "height" .= (1 :: Int)
        , "slot" .= (42 :: Int)
        ]

txId :: Text
txId = Text.replicate 64 "a"

blockId :: Text
blockId = Text.replicate 64 "b"

propVector
    :: [FilePath]
    -> (Json.Value -> Json.Parser a)
    -> SpecWith ()
propVector vectors decoder = do
    prop "decode test vectors" $ withNumTests 1 $ monadicIO $ do
        forM_ [0 .. (length vectors) - 1] (\i -> shouldDecode (vectors !! i))
  where
    shouldDecode vector = do
        let errDecode = "Failed to decode JSON"
        value <- maybe (fail errDecode) pure =<< run (Json.decodeFileStrict vector)
        case Json.parse decoder value of
            Json.Error str -> do
                monitor $ counterexample (decodeUtf8 (Json.encode value))
                monitor $ counterexample str
                assert False
            Json.Success{} -> do
                assert True
