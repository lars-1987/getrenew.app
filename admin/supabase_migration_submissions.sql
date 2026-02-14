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

  -- Link the user's product to the catalogue entry
  UPDATE products SET catalogue_id = new_id WHERE id = p_product_id AND catalogue_id IS NULL;

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
  -- Only link if not already linked
  UPDATE products SET catalogue_id = p_catalogue_id WHERE id = p_product_id AND catalogue_id IS NULL;

  -- Increment user count on the catalogue entry
  IF FOUND THEN
    UPDATE product_catalogue SET user_count = user_count + 1, updated_at = NOW() WHERE id = p_catalogue_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 3. RLS POLICY (if needed)
-- ============================================
-- The admin dashboard uses the anon key with magic link auth.
-- The products table likely has RLS restricting SELECT to own products.
-- We need authenticated users (admin) to be able to read all products
-- for the submissions view. If your RLS blocks this, run:
--
-- CREATE POLICY "Admin can read all products for catalogue management"
--   ON products FOR SELECT
--   USING (auth.role() = 'authenticated');
--
-- NOTE: Only run this if the admin dashboard can't read the products table.
-- Your existing RLS may already allow authenticated reads.
