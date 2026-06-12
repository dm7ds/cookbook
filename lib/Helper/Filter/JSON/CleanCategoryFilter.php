<?php

namespace OCA\Cookbook\Helper\Filter\JSON;

use OCA\Cookbook\Helper\TextCleanupHelper;

/**
 * Clean the category of a recipe.
 *
 * Clean the categories of a recipe.
 *
 * A recipe may have multiple categories (comma-separated).
 * Recipes without category are assigned the empty string.
 */
class CleanCategoryFilter extends AbstractJSONFilter {
	/** @var TextCleanupHelper */
	private $textCleaner;

	public function __construct(TextCleanupHelper $cleanupHelper) {
		$this->textCleaner = $cleanupHelper;
	}

	#[\Override]
	public function apply(array &$json): bool {
		if (!isset($json['recipeCategory'])) {
			$json['recipeCategory'] = '';
			return true;
		}

		$cache = $json['recipeCategory'];

		// Support multiple categories: normalize to comma-separated string
		if (is_array($json['recipeCategory'])) {
			$categories = array_map(function ($cat) {
				return is_string($cat) ? $this->textCleaner->cleanUp($cat, true, true) : '';
			}, $json['recipeCategory']);
			$categories = array_filter($categories, function ($cat) {
				return strlen($cat) > 0;
			});
			$json['recipeCategory'] = implode(',', $categories);
		} elseif (is_string($json['recipeCategory'])) {
			$categories = array_map('trim', explode(',', $json['recipeCategory']));
			$categories = array_map(function ($cat) {
				return $this->textCleaner->cleanUp($cat, true, true);
			}, $categories);
			$categories = array_filter($categories, function ($cat) {
				return strlen($cat) > 0;
			});
			$json['recipeCategory'] = implode(',', $categories);
		} else {
			$json['recipeCategory'] = '';
		}

		return $cache !== $json['recipeCategory'];
	}
}
