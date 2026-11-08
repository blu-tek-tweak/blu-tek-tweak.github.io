#ifndef WAVE26_GRID_H
#define WAVE26_GRID_H

typedef struct { long column; long row; } Wave26GridCell;

// Inputs are zero-based logical cells. Screen dimensions, point sizes and
// widget padding cannot affect which wave a given occupied cell belongs to.
static inline Wave26GridCell Wave26MapGridSpan(long column, long row,
                                              long width, long height,
                                              long columns, long rows,
                                              long waveColumns, long waveRows) {
    long lastColumn = column + (width > 0 ? width : 1) - 1;
    long lastRow = row + (height > 0 ? height : 1) - 1;
    if (lastColumn >= columns) lastColumn = columns - 1;
    if (lastRow >= rows) lastRow = rows - 1;
    // In a tie choose the top/left cell, matching the existing span search.
    long centerColumn = (columns - 1) / 2, centerRow = (rows - 1) / 2;
    if (centerColumn < column) centerColumn = column;
    if (centerColumn > lastColumn) centerColumn = lastColumn;
    if (centerRow < row) centerRow = row;
    if (centerRow > lastRow) centerRow = lastRow;
    Wave26GridCell cell = {
        (2 * centerColumn + 1) * waveColumns / (2 * columns),
        (2 * centerRow + 1) * waveRows / (2 * rows)
    };
    return cell;
}

#endif
