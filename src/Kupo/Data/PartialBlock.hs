--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

module Kupo.Data.PartialBlock
    ( PartialBlock (..)
    , PartialTransaction(..)
    ) where

import Kupo.Prelude

import Kupo.Data.Cardano
    ( BinaryData
    , DatumHash
    , HasTransactionId (..)
    , Input
    , InputIndex
    , IsBlock (..)
    , Metadata
    , MetadataHash
    , Output
    , OutputReference
    , Point
    , Script
    , ScriptHash
    , TransactionId
    , UnsupportedSubTransactions (..)
    , emptyMetadata
    )

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-- | A partial representation of a Cardano Block. This only contains bits that
-- are relevant to kupo. Rest isn't indexed.
data PartialBlock = PartialBlock
    { blockPoint :: !Point
    , blockBody :: ![PartialTransaction]
    -- ^ The decoded transactions, empty when 'hasTransactionStubs'.
    , hasTransactionStubs :: !Bool
    -- ^ Whether Ogmios sent the Dijkstra transactions of this block without
    --   their bodies, as Ogmios versions before full Dijkstra support do.
    } deriving (Eq, Show)

-- | A partial transaction, analogous to 'PartialBlock', trimmed down to the
-- minimum.
data PartialTransaction = PartialTransaction
    { id :: !TransactionId
    , inputs :: ![Input]
    , outputs :: ![(OutputReference, Output)]
    , datums :: !(Map DatumHash BinaryData)
    , spendRedeemers :: !(Map InputIndex BinaryData)
    , scripts :: !(Map ScriptHash Script)
    , metadata :: !(Maybe (MetadataHash, Metadata))
    , appliedSubTransactions :: ![PartialTransaction]
    -- ^ The Dijkstra sub-transactions of a phase-2 valid transaction, in the order the ledger applies them.
    , unappliedSubTransactions :: ![PartialTransaction]
    -- ^ The Dijkstra sub-transactions of a phase-2 invalid transaction, which the ledger discards.
    } deriving (Eq, Show)

instance HasTransactionId PartialTransaction where
    getTransactionId = id

instance IsBlock PartialBlock where
    type BlockBody PartialBlock = PartialTransaction

    getPoint =
        blockPoint

    spentInputs =
        Set.fromList . inputs

    foldBlock fn result =
        foldrWithIndex fn result . blockBody

    checkSubTransactions PartialBlock{blockPoint, hasTransactionStubs} =
        when hasTransactionStubs $
            Left (UnverifiableSubTransactions blockPoint)

    subTransactions =
        appliedSubTransactions

    discardedSubTransactions =
        unappliedSubTransactions

    mapMaybeOutputs fn tx =
        let meta = maybe emptyMetadata snd (metadata tx)
         in mapMaybe (\outs -> uncurry fn outs meta) (outputs tx)

    witnessedDatums =
        datums

    witnessedScripts =
        scripts

    userDefinedMetadata =
        metadata

    spendRedeemer PartialTransaction{spendRedeemers} ix =
        Map.lookup ix spendRedeemers
