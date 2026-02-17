-- Renew App - Submissions Admin Tools
-- Run this in your Supabase SQL Editor BEFORE using the Submissions tab
-- These functions let the admin approve user products into the catalogue
-- or link them to existing catalogue entries.

-- ============================================
-- 1. APPROVE SUBMISSION
-- ============================================
-- Creates a new product_catalogue entry from a user's product
-- and links the product to it. Handles conflicts gracefully
-- (if the normalised brand+name already exists, increments user_count).
--
-- Usage: SELECT approve_submission('<product_id>', 'Name', 'Brand', 'category', 'ingredients', 'instructions', 'description');

CREATE OR REPLACE FUNCTION approve_submission(
  p_product_id UUID,
  p_brand TEXT,
  p_name TEXT,
  p_category TEXT DEFAULT NULL,
  p_ingredients TEXT DEFAULT NULL,
  p_instructions TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
  new_id UUID;
  v_brand_norm TEXT;
  v_name_norm TEXT;
BEGIN
  v_brand_norm := normalise_text(p_brand);
  v_name_norm := normalise_product_name(p_name);

  -- Insert or update catalogue entry
  INSERT INTO product_catalogue (brand, name, category, description, ingredients, instructions, brand_normalised, name_normalised, user_count)
  VALUES (p_brand, p_name, p_category, p_description, p_ingredients, p_instructions, v_brand_norm, v_name_norm, 1)
  ON CONFLICT (brand_normalised, name_normalised) DO UPDATE SET
    user_count = product_catalogue.user_count + 1,
    ingredients = COALESCE(product_catalogue.ingredients, EXCLUDED.ingredients),
    instructions = COALESCE(product_catalogue.instructions, EXCLUDED.instructions),
    description = COALESCE(product_catalogue.description, EXCLUDED.description),
    category = COALESCE(product_catalogue.category, EXCLUDED.category),
    updated_at = NOW()
  RETURNING id INTO new_id;

  -- Link the user's product and push catalogue data to it (fill gaps only)
  UPDATE products SET
    catalogue_id = new_id,
    ingredients = COALESCE(products.ingredients, p_ingredients),
    instructions = COALESCE(products.instructions, p_instructions),
    category = COALESCE(products.category, p_category),
    updated_at = NOW()
  WHERE id = p_product_id AND catalogue_id IS NULL;

  -- Also backfill any other products already linked to this catalogue entry
  UPDATE products SET
    ingredients = COALESCE(products.ingredients, p_ingredients),
    instructions = COALESCE(products.instructions, p_instructions),
    category = COALESCE(products.category, p_category),
    updated_at = NOW()
  FROM product_catalogue cat
  WHERE products.catalogue_id = new_id
    AND cat.id = new_id
    AND (products.ingredients IS NULL OR products.instructions IS NULL OR products.category IS NULL);

  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 2. LINK SUBMISSION
-- ============================================
-- Links a user's product to an existing catalogue entry
-- and increments the entry's user_count.
--
-- Usage: SELECT link_submission('<product_id>', '<catalogue_id>');

CREATE OR REPLACE FUNCTION link_submission(
  p_product_id UUID,
  p_catalogue_id UUID
) RETURNS VOID AS $$
BEGIN
  -- Link the product and push catalogue data to it (fill gaps only)
  UPDATE products SET
    catalogue_id = p_catalogue_id,
    ingredients = COALESCE(products.ingredients, cat.ingredients),
    instructions = COALESCE(products.instructions, cat.instructions),
    category = COALESCE(products.category, cat.category),
    updated_at = NOW()
  FROM product_catalogue cat
  WHERE products.id = p_product_id
    AND products.catalogue_id IS NULL
    AND cat.id = p_catalogue_id;

  -- Increment user count on the catalogue entry
  IF FOUND THEN
    UPDATE product_catalogue SET user_count = user_count + 1, updated_at = NOW() WHERE id = p_catalogue_id;

    -- Also backfill any other products linked to this catalogue entry with empty fields
    UPDATE products SET
      ingredients = COALESCE(products.ingredients, cat.ingredients),
      instructions = COALESCE(products.instructions, cat.instructions),
      category = COALESCE(products.category, cat.category),
      updated_at = NOW()
    FROM product_catalogue cat
    WHERE products.catalogue_id = p_catalogue_id
      AND cat.id = p_catalogue_id
      AND (products.ingredients IS NULL OR products.instructions IS NULL OR products.category IS NULL);
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 3. IMPROVED DUPLICATE DETECTION
-- ============================================
-- Uses pg_trgm trigram similarity for fuzzy name matching.
-- This catches duplicates with different names like:
--   "2% BHA Exfoliating Toner" vs "SKIN PERFECTING 2% BHA Liquid Exfoliant"
--
-- Run this to replace the existing view:

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE OR REPLACE VIEW catalogue_potential_duplicates AS
SELECT
  a.id AS entry_a_id,
  a.brand AS entry_a_brand,
  a.name AS entry_a_name,
  a.user_count AS entry_a_users,
  CASE WHEN a.ingredients IS NOT NULL THEN true ELSE false END AS entry_a_has_ingredients,
  b.id AS entry_b_id,
  b.brand AS entry_b_brand,
  b.name AS entry_b_name,
  b.user_count AS entry_b_users,
  CASE WHEN b.ingredients IS NOT NULL THEN true ELSE false END AS entry_b_has_ingredients
FROM product_catalogue a
JOIN product_catalogue b
  ON a.brand_normalised = b.brand_normalised
  AND a.id < b.id
  AND (
    -- Same normalised product name
    a.name_normalised = b.name_normalised
    -- Or one name contains the other (catches partial matches)
    OR a.name_normalised LIKE '%' || b.name_normalised || '%'
    OR b.name_normalised LIKE '%' || a.name_normalised || '%'
    -- Or fuzzy similarity (catches different phrasings of same product)
    OR similarity(a.name_normalised, b.name_normalised) > 0.3
  )
ORDER BY a.brand_normalised, a.name_normalised;
