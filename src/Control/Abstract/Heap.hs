{-# LANGUAGE GADTs, KindSignatures, RankNTypes, TypeOperators, UndecidableInstances #-}
module Control.Abstract.Heap
( Heap
, Configuration(..)
, Live
, getHeap
, putHeap
, alloc
, deref
, assign
-- * Garbage collection
, gc
-- * Effects
, Allocator(..)
, Deref(..)
, AddressError(..)
, runAddressError
, runAddressErrorWith
) where

import Control.Abstract.Evaluator
import Control.Abstract.Roots
import Data.Abstract.Configuration
import Data.Abstract.BaseError
import qualified Data.Abstract.Heap as Heap
import Data.Abstract.Heap (Heap)
import Data.Abstract.ScopeGraph (Declaration(..))
import Data.Abstract.Live
import Data.Abstract.Module (ModuleInfo)
import Data.Abstract.Name
import Data.Span (Span)
import qualified Data.Set as Set
import Prologue

-- | Retrieve the heap.
getHeap :: Member (State (Heap address address value)) effects => Evaluator address value effects (Heap address address value)
getHeap = get

-- | Set the heap.
putHeap :: Member (State (Heap address address value)) effects => Heap address address value -> Evaluator address value effects ()
putHeap = put

-- | Update the heap.
modifyHeap :: Member (State (Heap address address value)) effects => (Heap address address value -> Heap address address value) -> Evaluator address value effects ()
modifyHeap = modify'

-- box :: ( Member (Allocator address) effects
--        , Member (Deref value) effects
--        , Member Fresh effects
--        , Member (State (Heap address address value)) effects
--        , Ord address
--        )
--     => value
--     -> Evaluator address value effects address
-- box val = do
--   name <- gensym
--   addr <- alloc name
--   assign addr (Declaration name) val -- TODO This is probably wrong
--   pure addr

alloc :: Member (Allocator address) effects => Name -> Evaluator address value effects address
alloc = send . Alloc

-- | Dereference the given address in the heap, or fail if the address is uninitialized.
deref :: ( Member (Deref value) effects
         , Member (Reader ModuleInfo) effects
         , Member (Reader Span) effects
         , Member (Resumable (BaseError (AddressError address value))) effects
         , Member (State (Heap address address value)) effects
         , Ord address
         )
      => address
      -> Declaration
      -> Evaluator address value effects value
-- TODO: THIS IS WRONG we need to call Heap.lookup
deref addr declaration = gets (Heap.getSlot addr declaration) >>= maybeM (throwAddressError (UnallocatedAddress addr)) >>= send . DerefCell >>= maybeM (throwAddressError (UninitializedAddress addr))


-- | Write a value to the given address in the 'Allocator'.
assign :: ( Member (Deref value) effects
          , Member (State (Heap address address value)) effects
          , Ord address
          )
       => address
       -> Declaration
       -> value
       -> Evaluator address value effects ()
assign addr declaration value = do
  heap <- getHeap
  cell <- send (AssignCell value (fromMaybe lowerBound (Heap.getSlot addr declaration heap)))
  putHeap (Heap.setSlot addr declaration cell heap)


-- Garbage collection

-- | Collect any addresses in the heap not rooted in or reachable from the given 'Live' set.
gc :: ( Member (State (Heap address address value)) effects
      , Ord address
      , ValueRoots address value
      )
   => Live address                       -- ^ The set of addresses to consider rooted.
   -> Evaluator address value effects ()
gc roots =
  -- TODO: Implement frame garbage collection
  undefined
  -- modifyHeap (heapRestrict <*> reachable roots)

-- | Compute the set of addresses reachable from a given root set in a given heap.
reachable :: ( Ord address
             , ValueRoots address value
             )
          => Live address       -- ^ The set of root addresses.
          -> Heap address address value -- ^ The heap to trace addresses through.
          -> Live address       -- ^ The set of addresses reachable from the root set.
reachable roots heap = go mempty roots
  where go seen set = case liveSplit set of
          Nothing -> seen
          Just (a, as) -> undefined -- go (liveInsert a seen) $ case heapLookupAll a heap of
            -- Just values -> liveDifference (foldr ((<>) . valueRoots) mempty values <> as) seen
            -- _           -> seen


-- Effects

data Allocator address (m :: * -> *) return where
  Alloc   :: Name    -> Allocator address m address

data Deref value (m :: * -> *) return where
  DerefCell  :: Set value          -> Deref value m (Maybe value)
  AssignCell :: value -> Set value -> Deref value m (Set value)

instance PureEffect (Allocator address)

instance Effect (Allocator address) where
  handleState c dist (Request (Alloc name) k) = Request (Alloc name) (dist . (<$ c) . k)

instance PureEffect (Deref value)

instance Effect (Deref value) where
  handleState c dist (Request (DerefCell cell) k) = Request (DerefCell cell) (dist . (<$ c) . k)
  handleState c dist (Request (AssignCell value cell) k) = Request (AssignCell  value cell) (dist . (<$ c) . k)

data AddressError address value resume where
  UnallocatedAddress   :: address -> AddressError address value (Set value)
  UninitializedAddress :: address -> AddressError address value value

deriving instance Eq address => Eq (AddressError address value resume)
deriving instance Show address => Show (AddressError address value resume)
instance Show address => Show1 (AddressError address value) where
  liftShowsPrec _ _ = showsPrec
instance Eq address => Eq1 (AddressError address value) where
  liftEq _ (UninitializedAddress a) (UninitializedAddress b) = a == b
  liftEq _ (UnallocatedAddress a)   (UnallocatedAddress b)   = a == b
  liftEq _ _                        _                        = False

throwAddressError :: ( Member (Resumable (BaseError (AddressError address body))) effects
                     , Member (Reader ModuleInfo) effects
                     , Member (Reader Span) effects
                     )
                  => AddressError address body resume
                  -> Evaluator address value effects resume
throwAddressError = throwBaseError

runAddressError :: ( Effectful (m address value)
                   , Effects effects
                   )
                => m address value (Resumable (BaseError (AddressError address value)) ': effects) a
                -> m address value effects (Either (SomeExc (BaseError (AddressError address value))) a)
runAddressError = runResumable

runAddressErrorWith :: (Effectful (m address value), Effects effects)
                    => (forall resume . (BaseError (AddressError address value)) resume -> m address value effects resume)
                    -> m address value (Resumable (BaseError (AddressError address value)) ': effects) a
                    -> m address value effects a
runAddressErrorWith = runResumableWith
