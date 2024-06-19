{-# LANGUAGE BlockArguments, ViewPatterns, MultiWayIf #-}
{-# LANGUAGE ApplicativeDo #-}
module Sudoku.Solve where

import Clash.Prelude
import RetroClash.Utils

import Sudoku.Matrix
import Sudoku.Grid
import Sudoku.Stack

import Control.Arrow (second, (***))
import Data.Maybe

foldGrid :: (n * m * m * n ~ k + 1) => (a -> a -> a) -> Grid n m a -> a
foldGrid f = fold f . flattenGrid

unzipMatrix :: Matrix n m (a, b) -> (Matrix n m a, Matrix n m b)
unzipMatrix = (FromRows *** FromRows) . unzip . fmap unzip . matrixRows

unzipGrid :: Grid n m (a, b) -> (Grid n m a, Grid n m b)
unzipGrid = (Grid *** Grid) . unzipMatrix . fmap unzipMatrix . getGrid

neighbourMasks
    :: forall n m dom. (KnownNat n, KnownNat m, 1 <= m, 1 <= n, 1 <= n * m)
    => (HiddenClockResetEnable dom)
    => Grid n m (Signal dom (Cell n m), Signal dom Bool)
    -> Grid n m (Vec (3 * (n * m - 1)) (Signal dom (Mask n m)))
neighbourMasks cells =
    rowwise others masks .++. columnwise others masks .++. boxwise others masks
  where
    masks = uncurry cellMask <$> cells

    cellMask :: Signal dom (Cell n m) -> Signal dom Bool -> Signal dom (Mask n m)
    cellMask c is_unique = mux is_unique (Mask . complement . cellBits <$> c) (pure wildMask)

    (.++.) = liftA2 (++)
    infixr 5 .++.

data PropagatorResult
    = Failure
    | Stuck
    | Progress
    deriving (Generic, NFDataX, Eq, Show)

propagator
    :: forall n m dom k. (KnownNat n, KnownNat m, 1 <= n, 1 <= m, 2 <= n * m, n * m * m * n ~ k + 1)
    => (HiddenClockResetEnable dom)
    => Signal dom (Maybe (Sudoku n m))
    -> ( Signal dom PropagatorResult
       , Grid n m (Signal dom (Cell n m), Signal dom Bool)
       )
propagator load = (result, fmap (\(c, solved, _, _) -> (c, solved)) units)
  where
    loads :: Grid n m (Signal dom (Maybe (Cell n m)))
    loads = unbundle . fmap sequenceA $ load

    units :: Grid n m (Signal dom (Cell n m), Signal dom Bool, Signal dom Bool, Signal dom Bool)
    units = unit <$> loads <*> neighbourMasks grid

    grid = fmap (\(c, solved, _, _) -> (c, solved)) units

    fresh = register False $ isJust <$> load
    changed = foldGrid (liftA2 (.|.)) . fmap (\ (_, _, changed, _) -> changed) $ units
    failed  = foldGrid (liftA2 (.|.)) . fmap (\ (_, _, _, failed) ->  failed)  $ units

    result =
        mux fresh (pure Progress) $
        mux failed (pure Failure) $
        mux (not <$> changed) (pure Stuck) $
        pure Progress

    unit
        :: forall k. (KnownNat k)
        => Signal dom (Maybe (Cell n m))
        -> Vec k (Signal dom (Mask n m))
        -> (Signal dom (Cell n m), Signal dom Bool, Signal dom Bool, Signal dom Bool)
    unit load neighbour_masks = (r, isUnique <$> r, register False changed, (== conflicted) <$> r)
      where
        r :: Signal dom (Cell n m)
        r = register conflicted r'

        (r', changed) = unbundle do
            load <- load
            this <- r
            masks <- bundle neighbour_masks
            pure $ case load of
                Just new_cell -> (new_cell, True)
                Nothing -> (this', this' /= this)
                  where
                    this' = applyMasks this masks

controller
    :: forall n m dom k. (KnownNat n, KnownNat m, 1 <= n, 1 <= m, 2 <= n * m, n * m * m * n ~ k + 1)
    => (HiddenClockResetEnable dom)
    => Signal dom (Maybe (Sudoku n m))
    -> ( Signal dom (Maybe (Sudoku n m))
       , Signal dom (Maybe (StackCmd (Sudoku n m)))
       )
controller load = (enable solved grid, stack_cmd)
  where
    (result, grid_with_unique) = propagator step
    grid = bundle . fmap fst $ grid_with_unique
    solved  = foldGrid (liftA2 (.&.)) . fmap snd $ grid_with_unique

    (can_try, unzipGrid -> (next, after)) = second unflattenGrid . mapAccumL f (pure False) . flattenGrid $ grid_with_unique
      where
        f found (s, solved) = (found .||. this, unbundle $ mux this (splitCell <$> s) (dup <$> s))
          where
            this = (not <$> found) .&&. (not <$> solved)
            dup x = (x, x)

    step = load .<|>. enable (can_try .&&. result .== Stuck) (bundle next)
    stack_cmd =
        mux (result .== Stuck .&&. can_try) (Just . Push <$> bundle after) $
        mux (result .== Failure) (pure $ Just Pop) $
        pure Nothing
