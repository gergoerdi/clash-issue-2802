{-# LANGUAGE BlockArguments #-}
module Sudoku.Matrix where

import Clash.Prelude

newtype Matrix n m a = FromRows{ matrixRows :: Vec n (Vec m a) }
    deriving (Generic, NFDataX, BitPack)

instance Functor (Matrix n m) where
    fmap f = FromRows . fmap (fmap f) . matrixRows

instance (KnownNat n, KnownNat m) => Applicative (Matrix n m) where
    pure x = FromRows . pure . pure $ x
    mf <*> mx = FromRows $ zipWith (<*>) (matrixRows mf) (matrixRows mx)

instance (KnownNat n, KnownNat m, 1 <= n, 1 <= m) => Foldable (Matrix n m) where
    foldMap f = foldMap (foldMap f) . matrixRows

instance (KnownNat n, KnownNat m, 1 <= n, 1 <= m) => Traversable (Matrix n m) where
    traverse f = fmap FromRows . traverse (traverse f) . matrixRows

instance (KnownNat n, KnownNat m) => Bundle (Matrix n m a) where
    type Unbundled dom (Matrix n m a) = Matrix n m (Signal dom a)

    bundle = fmap FromRows . bundle . fmap bundle . matrixRows
    unbundle = FromRows . fmap unbundle . unbundle . fmap matrixRows

generateMatrix :: (KnownNat n, KnownNat m) => (Index n -> Index m -> a) -> Matrix n m a
generateMatrix f = FromRows $
    flip map indicesI \i ->
    flip map indicesI \j ->
    f i j

rowFirst :: Matrix n m a -> Vec (n * m) a
rowFirst = concat . matrixRows
