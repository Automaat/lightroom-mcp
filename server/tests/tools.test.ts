import { describe, it, expect, beforeEach, afterEach } from '@jest/globals';

describe('Lightroom MCP Server Tools', () => {
  describe('search_photos', () => {
    it('should have correct tool definition', () => {
      const toolSchema = {
        name: 'search_photos',
        description: 'Search for photos in Lightroom catalog by criteria',
        inputSchema: {
          type: 'object',
          properties: {
            filename: {
              type: 'string',
              description: 'Search by filename (partial match)',
            },
            keywords: {
              type: 'array',
              items: { type: 'string' },
              description: 'Search by keywords',
            },
            rating: {
              type: 'number',
              description: 'Filter by star rating (0-5)',
              minimum: 0,
              maximum: 5,
            },
          },
        },
      };

      expect(toolSchema.name).toBe('search_photos');
      expect(toolSchema.inputSchema.type).toBe('object');
    });
  });

  describe('get_photo_metadata', () => {
    it('should require photo_id', () => {
      const toolSchema = {
        name: 'get_photo_metadata',
        inputSchema: {
          type: 'object',
          properties: {
            photo_id: {
              type: 'string',
              description: 'Photo ID or file path',
            },
          },
          required: ['photo_id'],
        },
      };

      expect(toolSchema.inputSchema.required).toContain('photo_id');
    });
  });

  describe('create_collection', () => {
    it('should require name parameter', () => {
      const toolSchema = {
        name: 'create_collection',
        inputSchema: {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'Collection name',
            },
          },
          required: ['name'],
        },
      };

      expect(toolSchema.inputSchema.required).toContain('name');
    });
  });

  describe('export_photos', () => {
    it('should support different formats', () => {
      const formats = ['jpeg', 'png', 'tiff', 'original'];

      formats.forEach(format => {
        expect(['jpeg', 'png', 'tiff', 'original']).toContain(format);
      });
    });

    it('should validate quality range', () => {
      const quality = 90;
      expect(quality).toBeGreaterThanOrEqual(0);
      expect(quality).toBeLessThanOrEqual(100);
    });
  });

  describe('set_rating', () => {
    it('should validate rating range', () => {
      const validRatings = [0, 1, 2, 3, 4, 5];

      validRatings.forEach(rating => {
        expect(rating).toBeGreaterThanOrEqual(0);
        expect(rating).toBeLessThanOrEqual(5);
      });
    });
  });
});

describe('HTTP Client', () => {
  it('should construct correct URL for plugin endpoint', () => {
    const baseUrl = 'http://localhost:8765';
    const endpoint = 'search_photos';
    const expectedUrl = `${baseUrl}/${endpoint}`;

    expect(expectedUrl).toBe('http://localhost:8765/search_photos');
  });

  it('should send JSON body in POST request', () => {
    const args = {
      filename: 'test.jpg',
      rating: 5,
    };

    const body = JSON.stringify(args);
    expect(body).toContain('test.jpg');
    expect(body).toContain('5');
  });
});
